#!/usr/bin/env bash
# Local end-to-end smoke test. Needs NO Google Drive: everything happens in a temp directory with a
# local restic repository. Never touches real /workspace or /home/box roots (or any other backup system).
#   tests/smoke.sh            run (restic/rclone are reused from <repo>/bin or downloaded there)
#   KEEP_TMP=1 tests/smoke.sh keep the temp directory for inspection
# shellcheck disable=SC2016  # bash -c snippets expand later; fixture text stays literal
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
export AGENTS_DIR="$TMP/agents"
ALERT_CHANNEL_REQUIRED=0
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
export RESTIC_CACHE_DIR="$TMP/cache"   # direct rs calls must also stay inside the fixture
export RESTIC_BACKUP_PASSWORD="smoke-test-password-$$-$RANDOM"
BIN="$REPO_DIR/bin"; PASSF="$SRC/gb-secrets/restic-pass"
rs() { "$BIN/restic" -r "$REPO" --password-file "$PASSF" "$@"; }
nsnap() { rs snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }
ntag() { rs snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(sum(1 for s in json.load(sys.stdin) if sys.argv[1] in (s.get("tags") or [])))' "$1"; }
tree_sum() { (cd "$1" && find . -type f ! -name '*.db' ! -name restic-pass -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }

step "restic timeout selection and rclone transport defaults (fake binaries)"
mkdir -p "$TMP/unit-bin"
printf '#!/usr/bin/env bash\nprintf "direct:%%s\\n" "$1"\n' > "$TMP/unit-bin/restic"
chmod +x "$TMP/unit-bin/restic"
check "R and RT select subcommand budgets; explicit overrides including zero win" bash -c '
  source "$1/lib.sh"
  GB_BIN="$2/unit-bin"
  timeout() { printf "%s\n" "$3"; }
  for wrapper in R RT; do
    for cmd in tag unlock snapshots cat forget backup check prune ls stats; do
      case "$cmd" in tag|unlock|snapshots|cat) expected=10m;; forget) expected=30m;; *) expected=3h;; esac
      [[ $("$wrapper" "$cmd") == "$expected" ]] || exit 1
      [[ $(R_TIMEOUT=7s "$wrapper" "$cmd") == 7s ]] || exit 1
      [[ $(R_TIMEOUT=0 "$wrapper" "$cmd") == "direct:$cmd" ]] || exit 1
    done
  done
' _ "$REPO_DIR" "$TMP"
mkdir -p "$TMP/hang-bin"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$TMP/hang-bin/restic"; chmod +x "$TMP/hang-bin/restic"
check "default-bounded timeout alerts; a caller-set R_TIMEOUT does not" bash -c '
  source "$1/lib.sh"
  GB_BIN="$2/hang-bin"; RESTIC_TIMEOUT_META=1
  rc=0; R snapshots >/dev/null 2>&1 || rc=$?; [[ $rc == 124 ]] || exit 1
  grep -q "restic snapshots timed out" "$GB_STATE/ALERT" || exit 1
  rm -f "$GB_STATE/ALERT"
  rc=0; R_TIMEOUT=1 R snapshots >/dev/null 2>&1 || rc=$?; [[ $rc == 124 ]] || exit 1
  [[ ! -s "$GB_STATE/ALERT" ]]
' _ "$REPO_DIR" "$TMP"
for net in default empty; do
  { cat "$TMP/config.env"; echo 'export RESTIC_REPOSITORY="rclone:fixture:repo"';
    echo 'RCLONE_SERVE_ARGS="--timeout 9m"'
    if [[ $net == empty ]]; then echo 'RCLONE_NET_ARGS=""'; else echo 'unset RCLONE_NET_ARGS'; fi
  } > "$TMP/net.env"
  check "transport args in both arrays: $net" env GB_CONFIG="$TMP/net.env" bash -c '
    source "$1/lib.sh"
    for args in "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"; do
      if [[ $2 == default ]]; then
        [[ $args == *"--contimeout 30s --timeout 2m --low-level-retries 5 --timeout 9m"* ]] || exit 1
      else
        [[ $args == *"--timeout 9m"* && $args != *--contimeout* && $args != *--low-level-retries* ]] || exit 1
      fi
    done
  ' _ "$REPO_DIR" "$net"
done

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

step "hardening: umask, timeouts, lock age, heartbeat, trash args, old-config defaults"
check "state/logs/staging are chmod 700" test "$(stat -c %a "$TMP/state" "$TMP/logs" "$TMP/staging" | sort -u)" = 700
rc=0; bash -c 'source "$1/lib.sh"; R_TIMEOUT=1 _rt sleep 5' _ "$REPO_DIR" >/dev/null 2>&1 || rc=$?
check "R/_rt: a call over its time limit is killed (rc 124)" test "$rc" = 124
{ cat "$TMP/config.env"; echo 'RESTIC_TIMEOUT_BACKUP=0.05'; } > "$TMP/config-to.env"
echo "timeout probe" > "$SRC/docs/to.txt"; sleep 1
rc=0; GB_CONFIG="$TMP/config-to.env" "$REPO_DIR/backup.sh" >/dev/null 2>&1 || rc=$?
check "backup.sh: restic over RESTIC_TIMEOUT_BACKUP -> exit 124/137 + TIMED OUT alert" test "$rc" = 124 -o "$rc" = 137
check "timeout alert text" grep -q 'TIMED OUT' "$TMP/state/ALERT"
rm -f "$SRC/docs/to.txt"; "$REPO_DIR/status.sh" --ack >/dev/null 2>&1
( exec 7>>"$TMP/state/backup.lock"; flock 7; exec sleep 60 ) & LP=$!; sleep 1   # $LP itself holds the lock
echo "$(( $(date +%s) - 20 * 3600 )) $LP backup.sh auto" > "$TMP/state/lock-holder"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "status flags backup.lock held for 20h" grep -q 'backup.lock held for 20h' "$TMP/status.out"
"$REPO_DIR/backup.sh" --quick >/dev/null 2>&1 || true
check "a skipped backup raises the lock-age alert" grep -q 'backup.lock held for 20h' "$TMP/state/ALERT"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
echo "$(( $(date +%s) - 20 * 3600 )) 999999999 gone" > "$TMP/state/lock-holder"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "orphaned lock retains recorded age and reports leftover holders" grep -q 'backup.lock held for 20h; orphaned' "$TMP/status.out"
kill "$LP" 2>/dev/null || true; wait "$LP" 2>/dev/null || true; "$REPO_DIR/status.sh" --ack >/dev/null 2>&1
( exec 7>>"$TMP/state/scheduler.lock"; flock 7; exec sleep 60 ) & SP=$!; sleep 1
echo $(( $(date +%s) - 3 * 3600 )) > "$TMP/state/scheduler.heartbeat"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "status flags a scheduler loop whose heartbeat is 3h old" grep -q 'has not ticked for 180 min' "$TMP/status.out"
date +%s > "$TMP/state/scheduler.heartbeat"
"$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "a fresh heartbeat is not flagged" not grep -q 'has not ticked' "$TMP/status.out"
kill "$SP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true; rm -f "$TMP/state/scheduler.heartbeat"
{ cat "$TMP/config.env"; echo 'export RESTIC_REPOSITORY="rclone:fake:folder"'; } > "$TMP/config-rc.env"
ta=$(GB_CONFIG="$TMP/config-rc.env" bash -c 'source "$1/lib.sh"; printf "%s|%s" "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "forget/prune (RT) use --drive-use-trash=true, normal calls keep false" bash -c '[[ "${1%%|*}" == *use-trash=false* && "${1#*|}" == *use-trash=true* && "${1#*|}" != *use-trash=false* ]]' _ "$ta"
{ cat "$TMP/config-rc.env"; echo 'PRUNE_USE_TRASH=0'; } > "$TMP/config-rc0.env"
ta0=$(GB_CONFIG="$TMP/config-rc0.env" bash -c 'source "$1/lib.sh"; printf "%s|%s" "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "PRUNE_USE_TRASH=0: forget/prune (RT) pass --drive-use-trash=false explicitly, never true" bash -c '[[ "${1#*|}" == *use-trash=false* && "${1#*|}" != *use-trash=true* ]]' _ "$ta0"
check "PRUNE_USE_TRASH=0: normal calls unchanged (still false)" bash -c '[[ "${1%%|*}" == *use-trash=false* && "${1%%|*}" == "${2%%|*}" ]]' _ "$ta0" "$ta"
{ cat "$TMP/config-rc.env"; echo 'RCLONE_SERVE_ARGS="--tpslimit 8"'; } > "$TMP/config-rcn.env"
tan=$(GB_CONFIG="$TMP/config-rcn.env" bash -c 'source "$1/lib.sh"; printf "%s" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "default PRUNE_USE_TRASH=1 adds --drive-use-trash=true even without the flag in RCLONE_SERVE_ARGS" bash -c '[[ "$1" == *use-trash=true* && "$1" != *use-trash=false* ]]' _ "$tan"
check "check.sh prunes via RT (Drive trash): the logged restic call is RT prune" grep -q 'caller=check.sh:main .*wrapper=RT cmd=prune' "$TMP"/logs/backup-*.log
{ cat "$TMP/config.env"; echo 'unset RCLONE_NET_ARGS RESTIC_TIMEOUT_META RESTIC_TIMEOUT_FORGET RESTIC_TIMEOUT RESTIC_TIMEOUT_BACKUP RESTIC_TIMEOUT_CHECK LOCK_ALERT_HOURS HEARTBEAT_MAX_MIN PRUNE_USE_TRASH RCLONE_TIMEOUT'; } > "$TMP/config-old.env"
run_ok "an older config.env without the new settings still works (lib.sh defaults)" env GB_CONFIG="$TMP/config-old.env" "$REPO_DIR/status.sh" --local
check "...and prints Overall" grep -q '^Overall:' "$TMP/last.out"

step "restore: host fallback"
{ cat "$TMP/config.env"; echo 'BACKUP_HOST=renamed-host'; } > "$TMP/config-host.env"
rc=0; GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" list >"$TMP/rh.out" 2>&1 || rc=$?
check "restore.sh list with a host that has 0 snapshots fails loudly (exit 4)" test "$rc" = 4
check "...and lists the hosts that do have snapshots" grep -q 'Hosts in this repository.*grokbox' "$TMP/rh.out"
run_ok "restore.sh --any-host list" env GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" --any-host list
run_ok "restore.sh --host grokbox ls latest" env GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" --host grokbox ls latest "$SRC/docs"
rc=0; GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" latest "$SRC/docs" >/dev/null 2>&1 || rc=$?
check "restore with a wrong host restores nothing (exit 4)" test "$rc" = 4

step "auth-gdrive.sh --test (no network needed for the no-token case)"
rc=0; "$REPO_DIR/auth-gdrive.sh" --test >"$TMP/auth.out" 2>&1 || rc=$?
check "--test without a token fails with exit 1 and says so" test "$rc" = 1
check "...naming the configured remote" grep -q 'no token for remote \[gdrive\]' "$TMP/auth.out"

step "sqlite-snapshot: a DB reached through a symlinked directory is staged once"
ln -s "$SRC/agent-data" "$SRC/alias-dir"
mkdir -p "$TMP/staging/sqlite$SRC/alias-dir"; cp "$TMP/staging/sqlite$SRC/agent-data/app.db" "$TMP/staging/sqlite$SRC/alias-dir/app.db"
python3 "$REPO_DIR/sqlite-snapshot.py" "$TMP/staging" "$TMP/sq.list" "$SRC/agent-data/*.db" "$SRC/alias-dir/*.db" 2>/dev/null
check "staged list holds the real path once" test "$(cat "$TMP/sq.list")" = "$SRC/agent-data/app.db"
check "stale copy under the alias path removed" test ! -e "$TMP/staging/sqlite$SRC/alias-dir/app.db"
rm -f "$SRC/alias-dir" "$TMP/sq.list" "$TMP/sq.list.identity.json"; rmdir "$TMP/staging/sqlite$SRC/alias-dir" 2>/dev/null || true

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
sem() { DELETED_BOTS_FILE="$TMP/deleted-agents.json" SERVER_EXPORT_DIR="$SE" AGENTS_DIR="$TMP/se-agents" python3 "$REPO_DIR/server-export-merge.py" "$@"; }
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
sem memory --out grokbox-main-and-shared --label GrokBox-Main "$FX/m2.txt" >/dev/null
check "memory --out writes its own file with its label" grep -q 'GrokBox-Main' "$SE/memory/grokbox-main-and-shared.md"
cat > "$FX/m3.txt" <<'EOF'
Top 50 matches for "c" in your memory (1 total):
- (2026-01-04) [journal] pasted inline: costs $5 and `x` stays literal
EOF
sem memory --remove --out pasted --label Pasted "$FX/m3.txt" >/dev/null
check "inline RecallMemory result pasted via quoted heredoc is ingested verbatim" grep -qF 'costs $5 and `x` stays literal' "$SE/memory/pasted.md"
check "age: a just-exported id passes" bash -c "SERVER_EXPORT_DIR='$SE' python3 '$REPO_DIR/server-export-merge.py' age tid-1 >/dev/null"
check "age: an id never exported fails (missed run)" bash -c "! SERVER_EXPORT_DIR='$SE' python3 '$REPO_DIR/server-export-merge.py' age tid-1 tid-missing >/dev/null"
tf=$(ls "$SE"/transcripts/tid-1__*.jsonl); head -n 9 "$tf" > "$SE/transcripts/tid-1__old-name.jsonl"; tail -n 7 "$tf" > "$tf.n"; mv "$tf.n" "$tf"
touch -d '2 days ago' "$SE/transcripts/tid-1__old-name.jsonl"; chmod 600 "$SE"/transcripts/*
sem repair >/dev/null
check "repair merges a renamed bot's split history into one file" test "$(find "$SE/transcripts" -maxdepth 1 -name 'tid-1__*.jsonl' -printf x | wc -c)" = 1 -a "$(texts)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12"
check "repair keeps the originals in state/replaced/" test "$(find "$SE/state/replaced" -name 'tid-1__*' | wc -l)" = 2
check "export dirs are 700, files 600" test -z "$(find "$SE" -type d ! -perm 700; find "$SE" -type f ! -perm 600)"
sum2=$(sha256sum "$SE"/transcripts/tid-1__*.jsonl | cut -d' ' -f1); pos2=$(sha256sum "$SE/state/positions.json" | cut -d' ' -f1)
{ printf 'Transcript of agent "Test Bot" (tid-1), positions 13\xe2\x80\x9314 of 15:\n\n'
  printf '{"role":"user","message":{"content":[{"type":"text","text":"m13"}]}}\n{"role":"user","message":{"content":[{"type":"te\n'; } > "$FX/bad.txt"
rc=0; sem ingest --remove "$FX/bad.txt" >/dev/null 2>"$TMP/bad.err" || rc=$?
check "ingest: a chunk with a truncated JSON line fails loudly (exit 3)" test "$rc" = 3
check "...the result file is kept (not removed) for a retry" test -f "$FX/bad.txt"
check "...the transcript and positions.json are unchanged (range not marked done)" test "$(sha256sum "$SE"/transcripts/tid-1__*.jsonl | cut -d' ' -f1)/$(sha256sum "$SE/state/positions.json" | cut -d' ' -f1)" = "$sum2/$pos2"
page 12 14 15 m12 m13 m14 > "$FX/p4.txt"; sem ingest --remove "$FX/p4.txt" >/dev/null
check "atomic append: new lines added, no temp file left" test "$(texts)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14" -a -z "$(find "$SE/transcripts" -name '*.tmp')"

echo; echo "smoke test: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
