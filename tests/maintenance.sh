#!/usr/bin/env bash
# Lane GLM tests: PRUNE_USE_TRASH serve args + docs, server-export-merge.py exit codes / atomic
# pending writes / in-place append, restore.sh (--help, exit codes, private temp, backup.lock),
# LOG_RETENTION_DAYS cleanup, and the nightly quota/disk check. Offline: local restic repo in a
# temp dir, a fake rclone for the Drive quota, no network, no real secrets.
#   tests/glm.sh            run (restic is reused from <repo>/bin)
#   KEEP_TMP=1 tests/glm.sh keep the temp directory for inspection
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grokbox-glm.XXXXXX")"
[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] || { echo "refusing: temp dir $TMP is not under /tmp"; exit 1; }
cleanup() { [[ -n "${KEEP_TMP:-}" ]] && { echo "kept $TMP"; return; }
  chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RCLONE_CONFIG
BIN="$REPO_DIR/bin"
[[ -x "$BIN/restic" ]] || { echo "bin/restic missing (run tests/smoke.sh once to download it)"; exit 1; }

PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N+1)); echo "  ok   - $*"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
run_ok() { local d="$1"; shift; if "$@" >"$TMP/last.out" 2>&1; then pass "$d"; else fail "$d"; sed 's/^/       | /' "$TMP/last.out" | tail -15; fi; }
not() { ! "$@"; }
step() { echo; echo "== $*"; }
# rc_of CMD... -> the command's exit code (output discarded)
rc_of() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# --- shared fixture: a small source tree + a local restic repo, driven through a temp config
SRC="$TMP/src"; REPO="$TMP/restic-repo"; RTMPDIR="$TMP/rtmp"
mkdir -p "$SRC/docs" "$RTMPDIR" "$TMP/secrets" "$TMP/restore"
PASSF="$TMP/restic-pass"; printf 'glm-lane-pw-%s-%s' "$$" "$RANDOM" > "$PASSF"; chmod 600 "$PASSF"
cat > "$TMP/config.env" <<CFG
GB_BIN="$BIN"
GB_SECRETS="$TMP/secrets"
GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSF"
BACKUP_ROOTS=("$SRC")
BACKUP_HOST=glmtest
RESTORE_BASE="$TMP/restore"
CFG
export GB_CONFIG="$TMP/config.env"
rs() { "$BIN/restic" -r "$REPO" --password-file "$PASSF" "$@"; }
for i in 0 1 2 3 4 5 6 7 8 9; do printf 'glm-%s\n' "$i" > "$SRC/docs/file$i.txt"; done
rs init >/dev/null 2>&1
rs backup --host glmtest --tag auto "$SRC" >/dev/null 2>&1

step "item 1: PRUNE_USE_TRASH -> rclone serve args (RT) for forget/prune"
cp "$TMP/config.env" "$TMP/rc.env"; echo 'export RESTIC_REPOSITORY="rclone:fake:GrokBox/restic"' >> "$TMP/rc.env"
ta=$(GB_CONFIG="$TMP/rc.env" bash -c 'source "$1/lib.sh"; printf "%s|%s" "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "default (1): forget/prune use --drive-use-trash=true, normal calls keep false" bash -c '[[ "${1%%|*}" == *use-trash=false* && "${1#*|}" == *use-trash=true* && "${1#*|}" != *use-trash=false* ]]' _ "$ta"
cp "$TMP/rc.env" "$TMP/rc0.env"; echo 'PRUNE_USE_TRASH=0' >> "$TMP/rc0.env"
ta0=$(GB_CONFIG="$TMP/rc0.env" bash -c 'source "$1/lib.sh"; printf "%s|%s" "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "PRUNE_USE_TRASH=0: forget/prune pass --drive-use-trash=false explicitly, never true" bash -c '[[ "${1#*|}" == *use-trash=false* && "${1#*|}" != *use-trash=true* ]]' _ "$ta0"
check "PRUNE_USE_TRASH=0: normal calls unchanged (still false)" bash -c '[[ "${1%%|*}" == "${2%%|*}" ]]' _ "$ta0" "$ta"
cat > "$TMP/old.env" <<CFG
GB_BIN="$BIN"; GB_SECRETS="$TMP/secrets"; GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"
GB_STAGING="$TMP/staging"; RESTIC_CACHE_DIR="$TMP/cache"; BACKUP_ROOTS=("$SRC")
RCLONE_SERVE_ARGS="--drive-use-trash=false --tpslimit 8"
export RESTIC_REPOSITORY="rclone:fake:GrokBox/restic"
CFG
tao=$(GB_CONFIG="$TMP/old.env" bash -c 'source "$1/lib.sh"; printf "%s" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "older config.env without PRUNE_USE_TRASH: lib.sh default is trash ON (true)" bash -c '[[ "$1" == *use-trash=true* && "$1" != *use-trash=false* ]]' _ "$tao"
check "README documents the trash opt-out" grep -q 'PRUNE_USE_TRASH=0' "$REPO_DIR/README.md"
check "config.env.example documents the trash opt-out" grep -q 'PRUNE_USE_TRASH=0' "$REPO_DIR/config.env.example"
check "AGENTS.md documents the trash opt-out" grep -q 'PRUNE_USE_TRASH=0' "$REPO_DIR/AGENTS.md"

step "item 5: server-export-merge.py ingest exit codes + atomic/append writes"
SE="$TMP/server-export"; FX="$TMP/se-fx"; mkdir -p "$FX" "$TMP/se-agents/glm-t1"
echo '{"name":"Glm Bot"}' > "$TMP/se-agents/glm-t1/profile.json"
# page ID A B N MSG... -> a ReadTranscript result file (header, JSON lines, footer)
page() { local id=$1 a=$2 b=$3 n=$4; shift 4; {
  printf 'Transcript of agent "Glm Bot" (%s), positions %s\xe2\x80\x93%s of %s:\n\n' "$id" "$a" "$b" "$n"
  for m in "$@"; do printf '{"role":"user","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$m"; done
  [[ $a -gt 0 ]] && printf '\nOlder messages remain: call ReadTranscript again with the same in and before=%s.\n' "$a"; true; }; }
sem() { SERVER_EXPORT_DIR="$SE" AGENTS_DIR="$TMP/se-agents" python3 "$REPO_DIR/server-export-merge.py" "$@"; }
texts() { python3 -c 'import sys,json,glob
print(" ".join(json.loads(l)["message"]["content"][0]["text"]
              for f in sorted(glob.glob(sys.argv[1]+"/transcripts/"+sys.argv[2]+"__*.jsonl")) for l in open(f) if l.strip()))' "$SE" "$1"; }
tfile() { ls "$SE"/transcripts/"$1"__*.jsonl; }
page glm-t1 0 2 9 m0 m1 m2 > "$FX/a0.txt"
check "first page ingests (exit 0)" test "$(rc_of sem ingest "$FX/a0.txt")" = 0
ino=$(stat -c %i "$(tfile glm-t1)")
page glm-t1 3 5 9 m3 m4 m5 > "$FX/a1.txt"; sem ingest "$FX/a1.txt" >/dev/null
check "exact-continuation page appended in place (same inode, no full rewrite)" test "$(stat -c %i "$(tfile glm-t1)")" = "$ino"
page glm-t1 6 8 9 m6 m7 m8 > "$FX/a2.txt"; sem ingest "$FX/a2.txt" >/dev/null
check "three pages stitched oldest-first" test "$(texts glm-t1)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8"
check "no .tmp files left" test -z "$(find "$SE" -name '*.tmp')"
check "complete -> next prints {}" test "$(sem next | tr -d ' \n')" = '{}'
sum=$(sha256sum "$(tfile glm-t1)" | cut -d' ' -f1)
check "re-ingesting the same pages is a no-op (exit 0)" test "$(rc_of sem ingest "$FX/a0.txt" "$FX/a1.txt" "$FX/a2.txt")" = 0
check "...and leaves the transcript byte-identical" test "$(sha256sum "$(tfile glm-t1)" | cut -d' ' -f1)" = "$sum"
# rejected pages: exit 3, file kept, nothing recorded, the range stays "missing" and heals on retry
sum=$(sha256sum "$(tfile glm-t1)" | cut -d' ' -f1)
{ printf 'Transcript of agent "Glm Bot" (glm-t1), positions 9\xe2\x80\x9311 of 12:\n\n'
  printf '{"role":"user","message":{"content":[{"type":"text","text":"m9"}]}}\n{"role":"user","messa\n'; } > "$FX/bad.txt"
check "truncated JSON line -> ingest exits 3" test "$(rc_of sem ingest "$FX/bad.txt")" = 3
check "...the result file is kept for a retry" test -f "$FX/bad.txt"
check "...the transcript is unchanged" test "$(sha256sum "$(tfile glm-t1)" | cut -d' ' -f1)" = "$sum"
# a rejected NEWEST page never updates `total`, so next keeps printing {} - the exit code is the
# ONLY signal here (that is why the routines must check it, not the JSON output)
check "...next still prints {} for a rejected newest page (only exit 3 signals it)" test "$(sem next | tr -d ' \n')" = '{}'
page glm-t1 9 11 12 m9 m10 m11 > "$FX/a3.txt"
check "refetching the rejected range succeeds (exit 0)" test "$(rc_of sem ingest "$FX/a3.txt")" = 0
check "...transcript complete after the retry" test "$(texts glm-t1)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11"
printf 'a result file without any transcript header\n' > "$FX/nh.txt"
check "no transcript header -> ingest exits 3, file kept" test "$(rc_of sem ingest "$FX/nh.txt")" = 3 -a -f "$FX/nh.txt"
check "unreadable chunk file -> ingest exits 3" test "$(rc_of sem ingest "$FX/does-not-exist.txt")" = 3
page glm-t1 9 13 14 m9 m10 m11 m12 m13 > "$FX/ov.txt"
check "overlapping newest page de-duplicated on ingest (exit 0)" test "$(rc_of sem ingest --remove "$FX/ov.txt")" = 0
check "...overlap removed, new lines kept" test "$(texts glm-t1)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13"
# gap pages land in state/pending (atomically) until the missing older page arrives
page glm-t2 6 8 10 p6 p7 p8 > "$FX/g1.txt"; sem ingest "$FX/g1.txt" >/dev/null
check "gap page stored as pending" test -f "$SE/state/pending/glm-t2/6-8.jsonl"
check "pending page written atomically (600, no .tmp)" test "$(stat -c %a "$SE/state/pending/glm-t2/6-8.jsonl")" = 600 -a -z "$(find "$SE/state/pending" -name '*.tmp')"
check "next reports the gap as a before value" test "$(sem next | tr -d ' \n')" = '{"glm-t2":6}'
page glm-t2 0 5 10 p0 p1 p2 p3 p4 p5 > "$FX/g0.txt"; sem ingest "$FX/g0.txt" >/dev/null
check "filling the gap completes the transcript" test "$(texts glm-t2)" = "p0 p1 p2 p3 p4 p5 p6 p7 p8"
printf 'No conversation, agent, or subagent you can read from here has the id "glm-t3".\n' > "$FX/u.txt"
check "unreadable id (--id) recorded with exit 0" test "$(rc_of sem ingest --id glm-t3 "$FX/u.txt")" = 0
check "INDEX.md shows it as not readable" grep -q 'not readable' "$SE/INDEX.md"
check "age: a just-checked id passes (exit 0)" test "$(rc_of sem age glm-t1)" = 0
check "age: a never-exported id fails (exit 1)" test "$(rc_of sem age glm-t1 glm-missing)" = 1
check "no subcommand -> usage, exit 2" test "$(rc_of sem)" = 2
check "unknown subcommand -> usage, exit 2" test "$(rc_of sem bogus)" = 2

step "items 7+8: restore.sh --help, exit codes, private temp, backup.lock"
rc=0; GB_CONFIG=/nonexistent/config "$REPO_DIR/restore.sh" --help >"$TMP/h.out" 2>&1 || rc=$?
check "--help works with no config at all (before lib.sh/need_creds), exit 0" test "$rc" = 0
check "--help documents exit codes" grep -q 'Exit codes' "$TMP/h.out"
check "--help output has no code lines" not grep -q 'lib.sh' "$TMP/h.out"
rc=0; "$REPO_DIR/restore.sh" >"$TMP/h.out" 2>&1 || rc=$?
check "no arguments -> usage, exit 0" test "$rc" = 0
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" --host >"$TMP/h.out" 2>&1 || rc=$?
check "--host without a name -> exit 2" test "$rc" = 2
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" --bogus >"$TMP/h.out" 2>&1 || rc=$?
check "unknown option -> exit 2" test "$rc" = 2
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" list >"$TMP/r.out" 2>&1 || rc=$?
check "list works (exit 0, shows the host)" test "$rc" = 0 -a "$(grep -c glmtest "$TMP/r.out")" -gt 0
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" ls latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "ls works (exit 0)" test "$rc" = 0 -a "$(grep -c file0.txt "$TMP/r.out")" -gt 0
check "no shared restore-hosts.json.tmp left in state" not test -e "$TMP/state/restore-hosts.json.tmp"
check "private temp dir cleaned up (trap)" test -z "$(ls -A "$RTMPDIR")"
{ cat "$TMP/config.env"; echo 'BACKUP_HOST=other-host'; } > "$TMP/config-host.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" list >"$TMP/r.out" 2>&1 || rc=$?
check "list with a host that has 0 snapshots -> exit 4" test "$rc" = 4
check "...and lists the hosts that do have snapshots" grep -q 'Hosts in this repository.*glmtest' "$TMP/r.out"
mkdir -p "$TMP/notarepo"
{ cat "$TMP/config.env"; echo "export RESTIC_REPOSITORY=\"$TMP/notarepo\""; } > "$TMP/config-bad.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-bad.env" "$REPO_DIR/restore.sh" list >"$TMP/r.out" 2>&1 || rc=$?
check "unreachable repo -> exit 7" test "$rc" = 7
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" --any-host list >"$TMP/r.out" 2>&1 || rc=$?
check "--any-host list skips the host check (exit 0)" test "$rc" = 0
( exec 9>>"$TMP/state/backup.lock"; flock 9; exec sleep 120 ) & LPID=$!
# wait until the holder provably holds the lock before asserting on restore.sh's
# behaviour (a blind sleep here raced under load and blamed restore.sh for it)
held=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n 9 9>>"$TMP/state/backup.lock" 2>/dev/null || { held=yes; break; }
  sleep 1
done
check "test harness: the holder really holds backup.lock" test "$held" = yes
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" ls latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "read-only ls works while a backup holds backup.lock" test "$rc" = 0
{ cat "$TMP/config.env"; echo 'RESTORE_LOCK_WAIT=2'; } > "$TMP/config-w.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-w.env" "$REPO_DIR/restore.sh" latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "restore while the lock is held -> exit 8 after RESTORE_LOCK_WAIT" test "$rc" = 8
check "...with a clear message naming backup.lock" grep -q 'backup.lock' "$TMP/r.out"
check "no restore dir was created" test -z "$(find "$TMP/restore" -maxdepth 1 -name 'restore-*' 2>/dev/null)"
kill "$LPID" 2>/dev/null || true; wait "$LPID" 2>/dev/null || true
sleep 1
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "restore with a free lock -> exit 0" test "$rc" = 0
RD="$(find "$TMP/restore" -maxdepth 1 -name 'restore-*' | head -1)"
check "files really restored into the restore dir" test -f "$RD$SRC/docs/file0.txt"
check "lock-holder records the restore run" grep -q ' restore$' "$TMP/state/lock-holder"
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" nosuchsnap >"$TMP/r.out" 2>&1 || rc=$?
check "restic failure -> non-zero rc + clear message" test "$rc" != 0 -a "$(grep -c 'restic restore failed' "$TMP/r.out")" -gt 0
check "...and it raises an alert" grep -q 'restic restore of nosuchsnap failed' "$TMP/state/ALERT"
rm -f "$TMP/state/ALERT"
rm "$SRC/docs/file5.txt"; printf 'changed-live\n' > "$SRC/docs/file0.txt"; sleep 1
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" latest --missing-only --yes "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "--missing-only: exit 0" test "$rc" = 0
check "--missing-only: missing file came back" test -f "$SRC/docs/file5.txt"
check "--missing-only: existing (modified) file NOT overwritten" test "$(cat "$SRC/docs/file0.txt")" = changed-live
check "private temp dir still clean" test -z "$(ls -A "$RTMPDIR")"

step "item 8: log retention (LOG_RETENTION_DAYS, default keep forever)"
L="$TMP/logs"; mkdir -p "$L" "$TMP/elsewhere"
echo old > "$L/backup-2000-01.log"; touch -d '400 days ago' "$L/backup-2000-01.log"
echo old > "$L/backup-2001-01.log"; touch -d '40 days ago' "$L/backup-2001-01.log"
echo keep > "$TMP/elsewhere/backup-1999-01.log"; touch -d '400 days ago' "$TMP/elsewhere/backup-1999-01.log"
echo a > "$L/alerts.log"; touch -d '400 days ago' "$L/alerts.log"
echo b > "$L/alerts-acked.log"; touch -d '400 days ago' "$L/alerts-acked.log"
run_ok "default LOG_RETENTION_DAYS: log-retention.sh is a no-op" env GB_CONFIG="$TMP/config.env" "$REPO_DIR/log-retention.sh"
check "default keeps everything" test -f "$L/backup-2000-01.log" -a -f "$L/backup-2001-01.log"
{ cat "$TMP/config.env"; echo 'LOG_RETENTION_DAYS=30'; } > "$TMP/lr.env"
run_ok "log-retention.sh with LOG_RETENTION_DAYS=30" env GB_CONFIG="$TMP/lr.env" "$REPO_DIR/log-retention.sh"
check "logs older than 30d deleted" not test -e "$L/backup-2000-01.log" -o -e "$L/backup-2001-01.log"
check "current month log kept" test -f "$L/backup-$(date +%Y-%m).log"
check "alerts.log never deleted (however old)" test -f "$L/alerts.log"
check "alerts-acked.log never deleted" test -f "$L/alerts-acked.log"
check "nothing outside GB_LOGS is touched" test -f "$TMP/elsewhere/backup-1999-01.log"
check "cleanup is logged" grep -q 'log retention: deleted 2 log file' "$L/backup-$(date +%Y-%m).log"
echo old > "$L/backup-2002-01.log"; touch -d '400 days ago' "$L/backup-2002-01.log"
{ cat "$TMP/config.env"; echo 'LOG_RETENTION_DAYS=not-a-number'; } > "$TMP/lrx.env"
run_ok "an invalid LOG_RETENTION_DAYS is not fatal" env GB_CONFIG="$TMP/lrx.env" "$REPO_DIR/log-retention.sh"
check "invalid setting keeps everything" test -f "$L/backup-2002-01.log"

step "item 8: quota + local disk monitoring (quota-check.sh)"
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/rclone" <<'EOF'
#!/usr/bin/env bash
# fake rclone for tests: only `about ... --json` is used (quota-check.sh); never touches the network
case " $* " in *" about "*)
  [[ "${FAKE_ABOUT_RC:-0}" != 0 ]] && exit "$FAKE_ABOUT_RC"
  [[ -n "${FAKE_ABOUT_JSON:-}" ]] && printf '%s\n' "$FAKE_ABOUT_JSON";; esac
exit 0
EOF
chmod +x "$FB/rclone"
mkq() { # mkq NAME SETTING -> temp config using the fake rclone + an rclone: repo
  { cat "$TMP/config.env"; echo "GB_BIN=\"$FB\""; echo 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"'; printf '%s\n' "$2"; } > "$TMP/$1"; }
mkq q1.env 'QUOTA_ALERT_PCT=90'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":102005473280,"trashed":0}' GB_CONFIG="$TMP/q1.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "quota-check exits 0" test "$rc" = 0
check "quota.status: drive_pct=95" grep -q '^drive_pct=95$' "$TMP/state/quota.status"
check "quota.status: drive_used bytes recorded" grep -q '^drive_used=102005473280$' "$TMP/state/quota.status"
check "quota.status: drive_total bytes recorded" grep -q '^drive_total=107374182400$' "$TMP/state/quota.status"
check "quota.status: local disk + time present" bash -c 'grep -q "^disk_pct=[0-9]" "$1" && grep -qE "^time=[0-9]+$" "$1"' _ "$TMP/state/quota.status"
check "alert at >= QUOTA_ALERT_PCT (95 >= 90)" grep -q 'Google Drive 95% full' "$TMP/state/ALERT"
rm -f "$TMP/state/ALERT"
mkq q2.env 'QUOTA_ALERT_PCT=98'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":10737418240}' GB_CONFIG="$TMP/q2.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "10% used: exit 0, no alert" test "$rc" = 0 -a ! -e "$TMP/state/ALERT"
check "quota.status updated (drive_pct=10)" grep -q '^drive_pct=10$' "$TMP/state/quota.status"
mkq q3.env 'QUOTA_ALERT_PCT=90'
rc=0; FAKE_ABOUT_RC=1 GB_CONFIG="$TMP/q3.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "rclone about failing: not fatal (exit 0)" test "$rc" = 0
check "...quota.status keeps disk values, drive values absent" bash -c 'grep -q "^disk_pct=" "$1" && ! grep -q "^drive_" "$1"' _ "$TMP/state/quota.status"
check "...and the failure is one log line" grep -q 'rclone about fakedrive: failed' "$L/backup-$(date +%Y-%m).log"
rc=0; FAKE_ABOUT_JSON='this is not json' GB_CONFIG="$TMP/q3.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "unparsable about output: not fatal, drive values absent" bash -c '[[ "$1" == 0 ]] && ! grep -q "^drive_" "$2"' _ "$rc" "$TMP/state/quota.status"
{ cat "$TMP/config.env"; echo 'QUOTA_ALERT_PCT=1'; } > "$TMP/q4.env"
rc=0; GB_CONFIG="$TMP/q4.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "local disk alert fires at >= QUOTA_ALERT_PCT" bash -c '[[ "$1" == 0 ]] && grep -q "local disk" "$2"' _ "$rc" "$TMP/state/ALERT"
check "non-rclone repo: no drive_* keys written" not grep -q '^drive_' "$TMP/state/quota.status"
rm -f "$TMP/state/ALERT"
check "check.sh runs both nightly jobs" bash -c 'grep -q "log-retention.sh" "$1" && grep -q "quota-check.sh" "$1"' _ "$REPO_DIR/check.sh"

echo; echo "glm lane tests: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
