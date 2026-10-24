#!/usr/bin/env bash
# Local end-to-end smoke test. Needs NO Google Drive: everything happens in a temp directory with a
# local restic repository. Never touches real /workspace or /home/box roots (or any other backup system).
#   tests/smoke.sh            run (restic/rclone are reused from <repo>/bin or downloaded there)
#   KEEP_TMP=1 tests/smoke.sh keep the temp directory for inspection
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grokbox-smoke.XXXXXX")"
[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] || { echo "refusing: temp dir $TMP is not under /tmp"; exit 1; }
cleanup() { [[ -n "${KEEP_TMP:-}" ]] && { echo "kept $TMP"; return; }
  "$REPO_DIR/install.sh" --stop-scheduler >/dev/null 2>&1 || true; chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RCLONE_CONFIG
SRC="$TMP/src"; STORES="$TMP/stores"; REPO="$TMP/restic-repo"
mkdir -p "$SRC/docs" "$SRC/agent-data/memory" "$SRC/gb-secrets" "$STORES/store1"

PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N+1)); echo "  ok   - $*"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
# run_ok DESC CMD...  : pass when CMD succeeds (output kept in $TMP/last.out, shown on failure)
run_ok() { local d="$1"; shift; if "$@" >"$TMP/last.out" 2>&1; then pass "$d"; else fail "$d"; sed 's/^/       | /' "$TMP/last.out" | tail -15; fi; }
not() { ! "$@"; }
step() { echo; echo "== $*"; }

# --- fake source tree: 40 files of ~20 KB, a live SQLite DB, a mounted-store outside the roots
python3 - "$SRC" "$STORES" <<'PY'
import os, sqlite3, sys, random
src, stores = sys.argv[1:3]
random.seed(7)
for i in range(40):
    with open(f"{src}/docs/file{i:02d}.bin", "wb") as f: f.write(random.randbytes(20000 + i))
open(f"{src}/agent-data/memory/notes.md", "w").write("remember: smoke test\n")
db = sqlite3.connect(f"{src}/agent-data/app.db")
db.execute("create table t(a)"); db.executemany("insert into t values (?)", [(i,) for i in range(100)]); db.commit(); db.close()
open(f"{stores}/store1/entry.txt", "w").write("mounted store content\n")
open(f"{stores}/store1/plain.db", "w").write("not staged by sqlite-snapshot\n")
open(f"{src}/gb-secrets/rclone.conf", "w").write("[gdrive]\ntype = drive\n")
PY

# --- temp config: example defaults, overridden to point entirely into $TMP
cat > "$TMP/config.env" <<CFG
GB_BIN="$REPO_DIR/bin"
GB_SECRETS="$SRC/gb-secrets"
GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export RESTIC_REPOSITORY="$REPO"
BACKUP_ROOTS=("$SRC"); QUICK_ROOTS=("\${BACKUP_ROOTS[@]}")
RESTORE_BASE="$TMP/restore"
KEEP=(--keep-last 100); KEEP_QUICK=(--keep-last 100)
GUARD_MIN_UPTIME_MIN=0; HYDRATION_LOG=""
SQLITE_GLOBS=("$SRC/**/*.db"); BRAIN_AGENT_DIRS=("$SRC/agent-data"); STORES_GLOB="$STORES/*"
BRAIN_EXPORT_MIN_INTERVAL_MIN=0
TEST_RESTORE_PATHS=("$SRC/agent-data"); TEST_RESTORE_RANDOM_FILES=10
CFG
export GB_CONFIG="$TMP/config.env"
export RESTIC_BACKUP_PASSWORD="smoke-test-password-$$-$RANDOM"
BIN="$REPO_DIR/bin"; PASSF="$SRC/gb-secrets/restic-pass"
rs() { "$BIN/restic" -r "$REPO" --password-file "$PASSF" "$@"; }
nsnap() { rs snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }
ntag() { rs snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(sum(1 for s in json.load(sys.stdin) if sys.argv[1] in (s.get("tags") or [])))' "$1"; }
tree_sum() { (cd "$1" && find . -type f ! -name '*.db' ! -name restic-pass -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }

step "install (binaries, password file from env)"
run_ok "install.sh" "$REPO_DIR/install.sh"
cp "$TMP/last.out" "$TMP/install.out"
check "restic + rclone present" test -x "$BIN/restic" -a -x "$BIN/rclone"
check "password file is chmod 600" test "$(stat -c %a "$PASSF")" = 600
check "password never printed" not grep -qF "$RESTIC_BACKUP_PASSWORD" "$TMP/install.out"
step "init"
run_ok "install.sh --init" "$REPO_DIR/install.sh" --init
check "repo created" test -f "$REPO/config"

step "dry run + first hourly backup"
run_ok "backup.sh --dry-run" "$REPO_DIR/backup.sh" --dry-run
check "dry run left no shared manifest/exclude state" not test -e "$TMP/state/manifest-auto.json" -o -e "$TMP/state/excludes.combined"
check "dry run created no snapshot" test "$(nsnap)" = 0
run_ok "backup.sh (auto)" "$REPO_DIR/backup.sh"
check "1 snapshot" test "$(nsnap)" = 1
rs ls latest > "$TMP/ls1.txt" 2>&1
check "restic-pass is NOT in the snapshot" not grep -q restic-pass "$TMP/ls1.txt"
check "other secrets (rclone.conf) are in the snapshot (BACKUP_SECRETS=1)" grep -q 'gb-secrets/rclone.conf' "$TMP/ls1.txt"
check "consistent SQLite copy staged + in snapshot" grep -q "staging/sqlite${SRC}/agent-data/app.db" "$TMP/ls1.txt"
check "live .db excluded from snapshot" not grep -qxF "$SRC/agent-data/app.db" "$TMP/ls1.txt"
check "brain INDEX.md written + in snapshot" grep -q 'staging/brain/INDEX.md' "$TMP/ls1.txt"
check "outside-root store mirrored into staging" test -f "$TMP/staging/brain/stores/store1/entry.txt"
check "outside-root .db that was NOT staged is copied as-is" test -f "$TMP/staging/brain/stores/store1/plain.db"
check "INDEX.md lists the store" grep -q 'store1' "$TMP/staging/brain/INDEX.md"
check "staged SQLite copy is readable" python3 -c 'import sqlite3,sys;assert sqlite3.connect(sys.argv[1]).execute("select count(*) from t").fetchone()[0]==100' "$TMP/staging/sqlite${SRC}/agent-data/app.db"

step "backup_paths: staging, config, secrets evaluated independently"
bp=$(bash -c 'source "$1/lib.sh"; backup_paths /nonexistent-root' _ "$REPO_DIR" 2>/dev/null)
check "staging, config file and secrets dir added when outside the roots" test "$(grep -cxF -e "$TMP/staging" -e "$GB_CONFIG" -e "$SRC/gb-secrets" <<<"$bp")" = 3

step "quick backup"
run_ok "backup.sh --quick" "$REPO_DIR/backup.sh" --quick
check "2 snapshots, 1 tagged quick" test "$(nsnap)/$(ntag quick)" = 2/1

step "modify files + second hourly backup"
echo "changed" >> "$SRC/docs/file03.bin"; echo "new file" > "$SRC/docs/new.txt"; rm "$SRC/docs/file05.bin"
sleep 1
run_ok "backup.sh (auto) #2" "$REPO_DIR/backup.sh"
check "3 snapshots, 2 tagged auto" test "$(nsnap)/$(ntag auto)" = 3/2

step "restore + checksum verify"
run_ok "restore.sh list" "$REPO_DIR/restore.sh" list
run_ok "restore.sh ls" "$REPO_DIR/restore.sh" ls latest "$SRC/docs"
run_ok "restore.sh latest" "$REPO_DIR/restore.sh" latest "$SRC"
RD="$(find "$TMP/restore" -maxdepth 1 -name 'restore-*' | head -1)"
check "restored tree checksums equal live tree" test -n "$RD" -a "$(tree_sum "$RD$SRC")" = "$(tree_sum "$SRC")"
sleep 1
rm "$SRC/docs/file10.bin"
run_ok "restore.sh --missing-only" "$REPO_DIR/restore.sh" latest --missing-only --yes "$SRC/docs"
check "missing file came back, nothing overwritten" test -f "$SRC/docs/file10.bin" -a "$(tail -c 8 "$SRC/docs/file03.bin" | tr -d '\0\n')" = changed

step "stale-computer guard (delete 50% of files)"
sleep 1
for i in $(seq 0 20); do rm -f "$SRC/docs/file$(printf %02d "$i").bin"; done
before=$(nsnap)
rc=0; "$REPO_DIR/backup.sh" >/dev/null 2>&1 || rc=$?
check "guard exits with 4" test "$rc" = 4
check "ALERT written" test -s "$TMP/state/ALERT"
check "no new snapshot" test "$(nsnap)" = "$before"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "status.sh --local shows the alert + ATTENTION NEEDED" grep -q 'ATTENTION NEEDED' "$TMP/status.out"
check "guard tripped -> latch state/GUARD_TRIPPED written" test -s "$TMP/state/GUARD_TRIPPED"
check "status.sh shows the latch" grep -q 'STALE GUARD LATCH' "$TMP/status.out"
"$REPO_DIR/check.sh" >/dev/null 2>&1 || true
check "check.sh skipped forget/prune while latched" grep -q 'forget/prune SKIPPED' "$TMP/logs/alerts.log"
rc=0; "$REPO_DIR/backup.sh" --force "smoke test: intentional" >/dev/null 2>&1 || rc=$?
check "--force bypasses the guard" test "$rc" = 0 -a "$(nsnap)" = $((before+1))
check "successful hourly backup clears the latch" test ! -e "$TMP/state/GUARD_TRIPPED"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1; check "status.sh --ack clears ALERT" test ! -e "$TMP/state/ALERT"

step "SQLite latch"
touch "$TMP/state/SQLITE_FAILED"
"$REPO_DIR/check.sh" >/dev/null 2>&1 || true
check "check.sh skipped forget/prune while SQLite-latched" grep -q 'SQLite staging failed earlier' "$TMP/logs/alerts.log"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "status.sh shows the SQLite latch" grep -q 'SQLITE LATCH' "$TMP/status.out"
sleep 1; run_ok "backup.sh (auto) with latch set" "$REPO_DIR/backup.sh"
check "fully successful hourly backup clears the SQLite latch" test ! -e "$TMP/state/SQLITE_FAILED"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "test restore, check, status"
run_ok "test-restore.sh" "$REPO_DIR/test-restore.sh"
check "last-test-restore written" test -s "$TMP/state/last-test-restore"
check "test restore dir deleted" not test -n "$(find "$TMP/restore" -maxdepth 1 -name 'restore-test-*')"
run_ok "check.sh" "$REPO_DIR/check.sh"
check "last-check written" test -s "$TMP/state/last-check"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "status.sh --local prints Overall" grep -q '^Overall:' "$TMP/status.out"
"$REPO_DIR/status.sh" >"$TMP/status-full.out" 2>&1 || true
check "status.sh (full) lists snapshots" grep -q '^Snapshots:' "$TMP/status-full.out"

step "status: no first success; incomplete snapshot"
sed "s#GB_STATE=\"$TMP/state\"#GB_STATE=\"$TMP/state2\"#" "$TMP/config.env" > "$TMP/config2.env"
mkdir -p "$TMP/state2"; echo $(( $(date +%s) - 3 * 3600 )) > "$TMP/state2/first-start"
GB_CONFIG="$TMP/config2.env" "$REPO_DIR/status.sh" --local >"$TMP/status2.out" 2>&1 || true
check "status flags no successful backup after the grace period" grep -q 'no successful hourly backup yet' "$TMP/status2.out"
{ cat "$TMP/config.env"; echo "RESTIC_PASSWORD_FILE=\"$TMP/nonexistent-pass\""; } > "$TMP/config3.env"
GB_CONFIG="$TMP/config3.env" "$REPO_DIR/status.sh" --local >"$TMP/status3.out" 2>&1 || true
check "status --local flags a missing password file" grep -q 'restic password file missing' "$TMP/status3.out"
mkdir -p "$TMP/state2"; echo $(( $(date +%s) - 40 * 86400 )) > "$TMP/state2/last-test-restore"; date +%s > "$TMP/state2/last-success"
GB_CONFIG="$TMP/config2.env" "$REPO_DIR/status.sh" --local >"$TMP/status2.out" 2>&1 || true
check "status --local flags a test restore older than 35 days" grep -q 'test restore is 40 days old' "$TMP/status2.out"
rm -f "$TMP/state2/last-test-restore" "$TMP/state2/last-success"
if [[ "$(id -u)" != 0 ]]; then
  echo unreadable > "$SRC/docs/unreadable.bin"; chmod 000 "$SRC/docs/unreadable.bin"
  good=$(cat "$TMP/state/last-success"); before=$(nsnap); sleep 1
  rc=0; "$REPO_DIR/backup.sh" >/dev/null 2>&1 || rc=$?
  check "incomplete snapshot: exit 6, snapshot kept, last-partial written" test "$rc" = 6 -a "$(nsnap)" = $((before+1)) -a -s "$TMP/state/last-partial"
  check "incomplete snapshot did not update last-success" test "$(cat "$TMP/state/last-success")" = "$good"
  "$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
  check "status flags the incomplete backup" grep -q 'INCOMPLETE' "$TMP/status.out"
  check "incomplete snapshot is tagged incomplete" test "$(ntag incomplete)" = 1
  chmod 600 "$SRC/docs/unreadable.bin"; rm -f "$SRC/docs/unreadable.bin"; sleep 1
  run_ok "backup.sh after fixing the file" "$REPO_DIR/backup.sh"
  check "good backup clears last-partial" test ! -e "$TMP/state/last-partial"
fi
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "scheduler start/stop (paused, so no jobs run)"
touch "$TMP/state/PAUSE"
run_ok "install.sh --schedule" "$REPO_DIR/install.sh" --schedule
sleep 1; "$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "scheduler reported running" grep -q 'Scheduler: running' "$TMP/status.out"
pid1=$(cat "$TMP/state/scheduler.pid")
"$REPO_DIR/install.sh" --schedule >/dev/null 2>&1; check "second --schedule is a no-op (same scheduler pid)" test "$(cat "$TMP/state/scheduler.pid")" = "$pid1"
"$REPO_DIR/install.sh" --stop-scheduler >/dev/null 2>&1; sleep 2
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "scheduler stopped" grep -q 'Scheduler: NOT running' "$TMP/status.out"

step "server-export-merge.py (synthetic ReadTranscript / RecallMemory fixtures)"
SE="$TMP/server-export"; FX="$TMP/se-fixtures"; mkdir -p "$FX" "$TMP/se-agents/tid-1"
echo '{"name":"Test Bot"}' > "$TMP/se-agents/tid-1/profile.json"
# page A B N MSG... -> a ReadTranscript result file (header, JSON lines, footer)
page() { local a=$1 b=$2 n=$3; shift 3; {
  printf 'Transcript of agent "Test Bot" (tid-1), positions %s\xe2\x80\x93%s of %s:\n\n' "$a" "$b" "$n"
  for m in "$@"; do printf '{"role":"user","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$m"; done
  [[ $a -gt 0 ]] && printf '\nOlder messages remain: call ReadTranscript again with the same in and before=%s.\n' "$a"; true; }; }
sem() { SERVER_EXPORT_DIR="$SE" AGENTS_DIR="$TMP/se-agents" python3 "$REPO_DIR/server-export-merge.py" "$@"; }
texts() { python3 -c 'import sys,json;print(" ".join(json.loads(l)["message"]["content"][0]["text"] for l in open(sys.argv[1]) if l.strip()))' "$SE"/transcripts/tid-1__*.jsonl; }
page 6 9 10 m6 m7 m8 m9 > "$FX/p2.txt"; page 0 2 10 m0 m1 m2 > "$FX/p0.txt"; page 3 5 10 m3 m4 m5 > "$FX/p1.txt"
out=$(sem ingest "$FX/p2.txt" "$FX/p0.txt"); check "a gap is reported as the next before value" test "$out" = '{"tid-1": 6}'
out=$(sem ingest "$FX/p1.txt"); check "filling the gap completes the transcript" test "$out" = '{}'
check "transcript stitched oldest-first" test "$(texts)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9"
sum1=$(sha256sum "$SE"/transcripts/*.jsonl | cut -d' ' -f1)
sem ingest "$FX/p0.txt" "$FX/p1.txt" "$FX/p2.txt" >/dev/null
check "re-ingesting the same pages is a no-op" test "$(sha256sum "$SE"/transcripts/*.jsonl | cut -d' ' -f1)" = "$sum1"
page 8 12 13 m8 m9 m10 m11 m12 > "$FX/p3.txt"; sem ingest --remove "$FX/p3.txt" >/dev/null
check "incremental newest page: overlap de-duplicated" test "$(texts)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12"
check "--remove deletes the result file" test ! -e "$FX/p3.txt"
printf 'No conversation, agent, or subagent you can read from here has the id "tid-2".\n' > "$FX/u.txt"
sem ingest --id tid-2 "$FX/u.txt" >/dev/null
check "unreadable id recorded in INDEX.md" grep -q 'not readable' "$SE/INDEX.md"
check "display name taken from the header / profile" grep -q '| Test Bot |' "$SE/INDEX.md"
check "positions.json says complete (next = {})" test "$(sem next | tr -d ' \n')" = '{}'
printf 'Top 50 matches for "a" in your memory (3 total):\n- (2026-01-01) [profile] fact one\n- (2026-01-02) [journal] fact two\n  wrapped\n' > "$FX/m1.txt"
printf 'Top 50 matches for "b" in your memory (3 total):\n- (2026-01-01) [profile] fact one\n- (2026-01-03) [journal] fact three\n' > "$FX/m2.txt"
sem memory "$FX/m1.txt" "$FX/m2.txt" >/dev/null; sem memory "$FX/m1.txt" >/dev/null
check "memory facts de-duplicated (3 unique, wrapped line joined)" test "$(grep -c '^- (' "$SE/memory/primary-bot-and-shared.md")" = 3 -a "$(grep -c 'fact two wrapped' "$SE/memory/primary-bot-and-shared.md")" = 1
check "export dirs are 700, files 600" test -z "$(find "$SE" -type d ! -perm 700; find "$SE" -type f ! -perm 600)"

echo; echo "smoke test: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
