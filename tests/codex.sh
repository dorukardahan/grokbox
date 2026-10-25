#!/usr/bin/env bash
# Offline regression tests: only synthetic credentials, mock remotes and our own child processes.
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d /tmp/grokbox-codex.XXXXXX)
CHILDREN=()
cleanup() {
  local pid
  for pid in "${CHILDREN[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT
PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N+1)); echo "  ok   - $*"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $*"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
not() { ! "$@"; }
mkdir -p "$TMP"/{bin,state,logs,staging,cache,fixture,src}
cat > "$TMP/test.env" <<CFG
GB_BIN="$TMP/bin"; GB_SECRETS="$TMP/fixture"; GB_STATE="$TMP/state"
GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export RESTIC_REPOSITORY="$TMP/local-repo"
BACKUP_ROOTS=("$TMP/src"); QUICK_ROOTS=("$TMP/src")
SQLITE_GLOBS=(); BRAIN_AGENT_DIRS=(); STORES_GLOB="$TMP/no-stores/*"
GUARD_MIN_UPTIME_MIN=0; HYDRATION_LOG=""; GUARD_MAX_DROP_PCT=100; GUARD_MTIME_BACK_HOURS=99999
RESTORE_BASE="$TMP/restore"
CFG
export GB_CONFIG="$TMP/test.env" TEST_ROOT="$TMP"
unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND RESTIC_BACKUP_PASSWORD
printf 'synthetic test fixture' > "$TMP/fixture/restic-pass"
printf '[gdrive]\ntype = drive\nscope = drive.file\ntoken = fixture-old\n' > "$TMP/fixture/rclone.conf"
echo fixture > "$TMP/src/unreadable"
mkdir -p "$TMP/state/rebuild-kit"; touch "$TMP/state/rebuild-kit/inventory.txt"
cat > "$TMP/bin/restic" <<'PY'
#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['TEST_ROOT']); args=sys.argv[1:]; cmd=args[0]
with (root/'calls').open('a') as f: f.write(cmd+'\n')
if cmd=='snapshots':
    print(json.dumps([{'short_id':'abcdef12','id':'abcdef12'}] if '--latest' in args else []))
elif cmd=='backup':
    rc=int(os.environ.get('FAKE_RC','0'))
    if rc==3:
        kind=os.environ.get('FAKE_KIND','unknown')
        print(json.dumps({'message_type':'error','during':'archival','item':str(root/'src/unreadable'),
                          'error':{'message':'open: permission denied' if kind=='permission' else 'repository read failure'}}))
    if rc in (0,3):
        print(json.dumps({'message_type':'summary','snapshot_id':'abcdef12','total_files_processed':2,
                          'total_bytes_processed':42,'data_added_packed':12}))
    sys.exit(rc)
elif cmd=='check':
    sys.exit(int(os.environ.get('FAKE_CHECK_RC','0')))
PY
cat > "$TMP/bin/rclone" <<'PY'
#!/usr/bin/env python3
import os,sys,time
from pathlib import Path
args=sys.argv[1:]; root=Path(os.environ['TEST_ROOT'])
i=args.index('--config'); config=Path(args[i+1]); del args[i:i+2]
if args[0]=='config':
    print('http://127.0.0.1:53682/auth?state=fixture',flush=True)
    if os.environ.get('CONSENT_WAIT')=='1':
        (root/'consent-ready').touch()
        while not (root/'consent-release').exists(): time.sleep(.05)
    if os.environ.get('CONSENT_FAIL')=='1': sys.exit(1)
    config.write_text('[gdrive]\ntype = drive\nscope = drive.file\ntoken = fixture-new\n')
elif args[0]=='about':
    counter=root/'about-count'
    n=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n))
    sys.exit(1 if n<=int(os.environ.get('ABOUT_FAILURES','0')) else 0)
elif args[0]=='lsf': print('config')
elif args[0]=='mkdir': sys.exit(int(os.environ.get('MKDIR_FAIL','0')))
else: sys.exit(2)
PY
chmod +x "$TMP/bin/"*
run_backup() { local rc=0; "$REPO_DIR/backup.sh" --no-forget > "$TMP/backup.out" 2>&1 || rc=$?; [[ "$rc" == "$1" ]]; }
check 'complete backup writes atomic result' run_backup 0
check 'complete metrics recorded' grep -qx 'bytes=42' "$TMP/state/last-backup.result"
for rc in 124 137; do
  export FAKE_RC=$rc
  check "timeout $rc returned" run_backup "$rc"
  check "timeout $rc recorded" grep -qx 'result=timeout' "$TMP/state/last-backup.result"
  : > "$TMP/calls"
  "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
  check "timeout $rc blocks prune" not grep -qx prune "$TMP/calls"
done
export FAKE_RC=3 FAKE_KIND=unknown
check 'unknown exit 3 remains incomplete' run_backup 6
check 'incomplete backup result' grep -qx 'result=incomplete' "$TMP/state/last-backup.result"
export FAKE_KIND=permission
check 'first unreadable omission is incomplete' run_backup 6
check 'repeated regular-file permission failure completes with warnings' run_backup 0
check 'unreadable count recorded' grep -qx 'unreadable=1' "$TMP/state/last-backup.result"
check 'unreadable path appears in alert' grep -q 'src/unreadable' "$TMP/state/ALERT"
export FAKE_CHECK_RC=1
: > "$TMP/calls"; rc=0; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1 || rc=$?
check 'failed check returns 5 and latches' test "$rc" = 5 -a -f "$TMP/state/CHECK_FAILED"
check 'failed check never prunes' not grep -qx prune "$TMP/calls"
export FAKE_CHECK_RC=0
: > "$TMP/calls"; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'passing check clears latch' test ! -e "$TMP/state/CHECK_FAILED"
check 'passing check permits prune' grep -qx 'pruned=1' "$TMP/state/last-check.result"
check 'check precedes prune' python3 -c 'import sys;x=open(sys.argv[1]).read().splitlines();assert x.index("check")<x.index("prune")' "$TMP/calls"
echo garbage > "$TMP/state/last-backup.result"
: > "$TMP/calls"; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'garbled backup result blocks prune' not grep -qx prune "$TMP/calls"

# Garbled/missing records are visible, and an unrelated lock cannot hide a dead heartbeat.
# shellcheck disable=SC2016 # evaluated in the child
bash -c 'exec 9>>"$1/state/backup.lock"; flock 9; exec sleep 120' _ "$TMP" & LP=$!; CHILDREN+=("$LP")
# shellcheck disable=SC2016 # evaluated in the child
bash -c 'exec 8>>"$1/state/scheduler.lock"; flock 8; exec sleep 120' _ "$TMP" & SP=$!; CHILDREN+=("$SP")
sleep .2
echo malformed > "$TMP/state/lock-holder"
echo "$(( $(date +%s) - 3*3600 ))" > "$TMP/state/scheduler.heartbeat"
"$REPO_DIR/status.sh" --local > "$TMP/status.out" 2>&1
check 'garbled lock record is visible' grep -q 'orphaned/unverifiable' "$TMP/status.out"
check 'busy unrelated lock does not hide stale heartbeat' grep -q 'has not ticked for' "$TMP/status.out"
kill "$LP" "$SP"; wait "$LP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true; CHILDREN=()
rm -f "$TMP/state/scheduler.heartbeat"

# Existing credentials remain untouched on failure; fake rclone never contacts a remote.
cp "$TMP/fixture/rclone.conf" "$TMP/old-config"
rc=0; CONSENT_FAIL=1 "$REPO_DIR/auth-gdrive.sh" --reauth --rclone-default-client > "$TMP/auth.out" 2>&1 || rc=$?
check 'failed consent returns failure' test "$rc" = 1
check 'failed consent preserves active config' cmp -s "$TMP/old-config" "$TMP/fixture/rclone.conf"
rm -f "$TMP/about-count"
rc=0; MKDIR_FAIL=1 "$REPO_DIR/auth-gdrive.sh" --reauth --rclone-default-client > "$TMP/auth.out" 2>&1 || rc=$?
check 'folder failure is explicit' grep -q 'folder creation failed' "$TMP/auth.out"
check 'folder failure preserves config' cmp -s "$TMP/old-config" "$TMP/fixture/rclone.conf"
rm -f "$TMP/about-count"
ABOUT_FAILURES=2 "$REPO_DIR/auth-gdrive.sh" --reauth --rclone-default-client > "$TMP/auth.out" 2>&1
check 'transient verification retries before swap' test "$(cat "$TMP/about-count")" = 3
check 'verified candidate swapped' not cmp -s "$TMP/old-config" "$TMP/fixture/rclone.conf"
CONSENT_WAIT=1 "$REPO_DIR/auth-gdrive.sh" --reauth --rclone-default-client > "$TMP/auth.out" 2>&1 & AP=$!; CHILDREN+=("$AP")
for _ in {1..100}; do [[ -f "$TMP/consent-ready" && -s "$TMP/state/auth-url.txt" ]] && break; sleep .1; done
"$REPO_DIR/auth-gdrive.sh" --test > "$TMP/auth-test.out" 2>&1
check '--test preserves concurrent consent URL' test -s "$TMP/state/auth-url.txt"
: > "$TMP/calls"; FAKE_RC=0 "$REPO_DIR/backup.sh" > "$TMP/busy.out" 2>&1
check 'consent lock pauses backup' test ! -s "$TMP/calls"
touch "$TMP/consent-release"; wait "$AP"; CHILDREN=()
check 'consent owner removes URL' test ! -e "$TMP/state/auth-url.txt"

# A live, unrelated recorded PID must not disguise an inherited lock holder.
# shellcheck disable=SC2016 # evaluated in the child
setsid bash -c 'exec 9>>"$1/state/backup.lock"; flock 9; echo ready > "$1/lock-ready"; exec sleep 120' _ "$TMP" & LP=$!; CHILDREN+=("$LP")
for _ in {1..100}; do [[ -f "$TMP/lock-ready" ]] && break; sleep .05; done
echo "$(( $(date +%s) - 20*3600 )) $$ backup.sh auto" > "$TMP/state/lock-holder"
"$REPO_DIR/status.sh" --local > "$TMP/status.out" 2>&1
check 'PID reuse is diagnosed as orphan' grep -q 'orphaned/unverifiable' "$TMP/status.out"
check 'orphan alert names actual holder' grep -q "$LP (sleep)" "$TMP/status.out"
echo "$(( $(date +%s) - 14*3600 )) $LP check.sh check" > "$TMP/state/lock-holder"
"$REPO_DIR/status.sh" --local > "$TMP/status.out" 2>&1
check 'slow sequential check avoids false 13h alert' not grep -q 'past job timeout' "$TMP/status.out"
python3 "$REPO_DIR/lock-control.py" force "$TMP/state/backup.lock" > "$TMP/force.out"
wait "$LP" 2>/dev/null || true; CHILDREN=()
check 'force terminates verified holder' not kill -0 "$LP" 2>/dev/null
rc=0; "$REPO_DIR/install.sh" --restart-scheduler --force > "$TMP/force.out" 2>&1 || rc=$?
check 'force refuses free lock' test "$rc" = 1
check 'free lock refusal explains recovery' grep -q 'backup.lock is free' "$TMP/force.out"

# Verify escaped process groups and waiters sharing the inode are treated differently.
rm -f "$TMP/lock-ready"
cat > "$TMP/holder.sh" <<'HOLDER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>>"$1/state/backup.lock"; flock 9
setsid bash -c 'trap "" TERM; echo $$ > "$1/escaped-pid"; exec sleep 120' _ "$1" &
echo ready > "$1/lock-ready"
wait
HOLDER
setsid bash "$TMP/holder.sh" "$TMP" & LP=$!; CHILDREN+=("$LP")
for _ in {1..100}; do [[ -f "$TMP/escaped-pid" ]] && break; sleep .05; done
EP=$(cat "$TMP/escaped-pid"); CHILDREN+=("$EP")
# shellcheck disable=SC2016 # evaluated in the child
bash -c 'exec 9>>"$1/state/backup.lock"; exec sleep 120' _ "$TMP" & WP=$!; CHILDREN+=("$WP")
python3 "$REPO_DIR/lock-control.py" force "$TMP/state/backup.lock" > "$TMP/force.out"
wait "$LP" 2>/dev/null || true
check 'force leaves an unrelated inode opener alive' kill -0 "$WP"
check 'force kills TERM-resistant escaped child group' python3 -c 'import pathlib,sys;p=pathlib.Path("/proc")/sys.argv[1]/"stat";assert not p.exists() or p.read_text().split(") ")[1].startswith("Z")' "$EP"
kill "$WP"; wait "$WP" 2>/dev/null || true; CHILDREN=()

# Real local restic JSON: permission errors are classified from actual output too.
if [[ $(id -u) != 0 ]]; then
  export RESTIC_REPOSITORY="$TMP/real-repo" RESTIC_PASSWORD_FILE="$TMP/fixture/restic-pass" RESTIC_CACHE_DIR="$TMP/cache"
  "$REPO_DIR/bin/restic" init > "$TMP/real.out" 2>&1
  chmod 000 "$TMP/src/unreadable"
  rc=0; "$REPO_DIR/bin/restic" backup --json --tag incomplete "$TMP/src" > "$TMP/real.json" 2>&1 || rc=$?
  check 'real local unreadable backup returns 3' test "$rc" = 3
  python3 "$REPO_DIR/backup-result.py" "$TMP/real.json" "$TMP/known.json" > "$TMP/classified"
  check 'real first unreadable error is incomplete' grep -qx normal "$TMP/classified"
  python3 "$REPO_DIR/backup-result.py" "$TMP/real.json" "$TMP/known.json" > "$TMP/classified"
  check 'real repeated unreadable error is warning' grep -qx warnings "$TMP/classified"
  chmod 600 "$TMP/src/unreadable"
fi

echo "$PASS_N passed, $FAIL_N failed"
(( FAIL_N == 0 ))
