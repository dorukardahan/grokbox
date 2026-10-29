#!/usr/bin/env bash
# Offline regression tests: only synthetic credentials, mock remotes and our own child processes.
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d /tmp/grokbox-locks.XXXXXX)
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
export AGENTS_DIR="$TMP/agents"
export DELETED_BOTS_FILE="$TMP/no-deleted-agents.json"
BACKUP_HOST=testhost; SNAPSHOT_LIST_RETRY_S=0
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
import json,os,sys,time
from pathlib import Path
root=Path(os.environ['TEST_ROOT']); args=sys.argv[1:]; cmd=args[0]
with (root/'calls').open('a') as f: f.write(cmd+'\n')
with (root/'args').open('a') as f: f.write(' '.join(args)+'\n')
def count(name):
    counter=root/name
    n=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n))
    return n
snapshot=root/'snapshot.json'
old_snapshot=root/'snapshot-old.json'
if os.environ.get('RESTIC_SLEEP')=='1':
    (root/'restic-ready').touch()
    while (root/'restic-wait').exists(): time.sleep(.05)
    sys.exit(0)
if cmd=='snapshots':
    n=count('list-count')
    if (n<=int(os.environ.get('LIST_FAILURES','0')) or
        str(n) in os.environ.get('LIST_FAIL_AT','').split(',') or
        (os.environ.get('FAIL_RETENTION')=='1' and 'incomplete' in args) or
        os.environ.get('FAIL_SNAPSHOTS')=='1'):
        print('Fatal: repository is already locked by PID 123 on testhost' if os.environ.get('LIST_LOCKED')=='1' else 'fixture listing failure',file=sys.stderr)
        print('discard this partial output')
        sys.exit(int(os.environ.get('LIST_RC','1')))
    snaps=[json.loads(snapshot.read_text())] if snapshot.exists() else []
    if old_snapshot.exists(): snaps.insert(0,json.loads(old_snapshot.read_text()))
    if '--tag' in args: snaps=[s for s in snaps if args[args.index('--tag')+1] in s['tags']]
    print(json.dumps(snaps))
elif cmd=='tag':
    n=count('tag-count')
    if '--remove' in args and args[args.index('--remove')+1]=='auto,quick':
        if count('cleanup-count')<=int(os.environ.get('CLEANUP_LOCKED','0')):
            print('Fatal: repository is already locked by PID 123 on testhost',file=sys.stderr)
            sys.exit(1)
    if n<=int(os.environ.get('TAG_LOCKED','0')) or (root/'repo-lock').exists():
        (root/'repo-lock').touch()
        print('Fatal: repository is already locked by PID 123 on testhost',file=sys.stderr)
        sys.exit(1)
    if n<=int(os.environ.get('TAG_FAILURES','0')):
        print('Fatal: unable to create lock in backend: fixture network error' if os.environ.get('TAG_NETWORK')=='1' else 'fixture tag failure',file=sys.stderr)
        sys.exit(1)
    if n<=int(os.environ.get('TAG_NOOP','0')):
        print('unable to modify the tags: ignoring; no snapshots were modified')
        sys.exit(0)
    snap=json.loads(snapshot.read_text())
    if args[-1]!=snap['id']:
        print('no snapshots were modified')
        sys.exit(0)
    duplicate=os.environ.get('TAG_DUP')=='1' and n==1
    if duplicate: old_snapshot.write_text(json.dumps(snap))
    old=snap['id']; snap['id']='cdefab34'; snap['short_id']=snap['id']; snap['original']=old
    remove=args[args.index('--remove')+1].split(',') if '--remove' in args else []
    snap['tags']=[t for t in snap['tags'] if t not in remove]
    if '--add' in args: snap['tags'].append(args[args.index('--add')+1])
    snapshot.write_text(json.dumps(snap))
    if duplicate or n<=int(os.environ.get('TAG_PARTIAL','0')): sys.exit(1)
elif cmd=='unlock':
    (root/'repo-lock').unlink(missing_ok=True)
elif cmd=='stats':
    print(json.dumps({'total_size':42}))
elif cmd=='ls':
    print(json.dumps({'struct_type':'node','type':'file','path':str(root/'src/unreadable'),
                      'size':8,'mtime':'2000-01-01T00:00:00Z'}))
elif cmd=='restore':
    target=Path(args[args.index('--target')+1]); dest=target/str(root/'src/unreadable').lstrip('/')
    dest.parent.mkdir(parents=True,exist_ok=True); dest.write_text('fixture\n')
elif cmd=='backup':
    if count('backup-count')<=int(os.environ.get('BACKUP_LOCKED','0')):
        print('Fatal: repository is already locked by PID 123 on testhost',file=sys.stderr)
        sys.exit(1)
    old_snapshot.unlink(missing_ok=True)
    assert os.environ.get('RESTIC_PROGRESS_FPS') == '0.01'
    print(json.dumps({'message_type':'status','percent_done':0.5}))
    if os.environ.get('NOTICE')=='1': print('rclone: rate limit notice')
    if os.environ.get('MALFORMED')=='1': print('{bad json')
    rc=int(os.environ.get('FAKE_RC','0'))
    if rc==3:
        kind=os.environ.get('FAKE_KIND','unknown')
        print(json.dumps({'message_type':'error','during':'archival','item':str(root/'src'/os.environ.get('ERROR_FILE','unreadable')),
                          'error':{'message':'open: permission denied' if kind=='permission' else 'repository read failure'}}))
    if rc in (0,3):
        tags=[args[i+1] for i,a in enumerate(args) if a=='--tag']
        host=args[args.index('--host')+1]
        snapshot.write_text(json.dumps({'id':'abcdef12','short_id':'abcdef12','tags':tags,
                                       'time':'2000-01-01T00:00:00Z','hostname':host,'paths':[str(root/'src')]}))
        print(json.dumps({'message_type':'summary','snapshot_id':'abcdef12','total_files_processed':2,
                          'total_bytes_processed':42,'data_added_packed':12}))
    sys.exit(rc)
elif cmd=='check':
    sys.exit(int(os.environ.get('FAKE_CHECK_RC','0')))
elif cmd=='forget' and '--tag' in args:
    tag=args[args.index('--tag')+1]
    if count('forget-'+tag+'-count')<=int(os.environ.get('FORGET_LOCKED','0')):
        print('Fatal: repository is already locked by PID 123 on testhost',file=sys.stderr)
        sys.exit(1)
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
check 'complete hourly success records its epoch in history' python3 - "$TMP/state" <<'PYHISTORY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
assert (p/'hourly-history').read_text().splitlines()==[(p/'last-success').read_text().strip()]
PYHISTORY
check 'normal backup lists snapshots exactly twice' python3 - "$TMP/args" <<'PYLISTS'
import sys
assert sum(line.startswith('snapshots ') for line in open(sys.argv[1])) == 2
PYLISTS
seq 946684800 946685204 > "$TMP/state/hourly-history"
check 'hourly success with a long history succeeds' run_backup 0
check 'hourly history retains the newest 400 epochs including this success' python3 - "$TMP/state" <<'PYHISTORY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); lines=(p/'hourly-history').read_text().splitlines()
assert len(lines)==400 and lines[0]=='946684806'
assert lines[-1]==(p/'last-success').read_text().strip()
assert not (p/'hourly-history.tmp').exists()
PYHISTORY
cp "$TMP/state/hourly-history" "$TMP/history-before-failure"
for rc in 124 137; do
  export FAKE_RC=$rc
  check "timeout $rc returned" run_backup "$rc"
  if [[ $rc == 137 ]]; then
    check 'early SIGKILL wording does not claim timeout grace' grep -q 'killed before the timeout elapsed' "$TMP/backup.out"
  fi
  check "timeout $rc recorded" grep -qx 'result=timeout' "$TMP/state/last-backup.result"
  check "timeout $rc never adds an hourly success" cmp -s "$TMP/history-before-failure" "$TMP/state/hourly-history"
  : > "$TMP/calls"
  "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
  check "timeout $rc blocks prune" not grep -qx prune "$TMP/calls"
done
export FAKE_RC=3 FAKE_KIND=unknown
check 'unknown exit 3 remains incomplete' run_backup 6
check 'incomplete backup result' grep -qx 'result=incomplete' "$TMP/state/last-backup.result"
# An incomplete latest hourly must make skipped maintenance visible, once per incident.
rm -f "$TMP/state/ALERT" "$TMP/state/alert-seen" "$TMP/state/prune-skipped-since"
for _ in 1 2; do
  : > "$TMP/calls"
  "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
  if [[ ! -f "$TMP/first-prune-skip" ]]; then cp "$TMP/state/prune-skipped-since" "$TMP/first-prune-skip"; fi
done
check 'incomplete hourly skips prune and records the reason' python3 - "$TMP" <<'PYPRUNE'
from pathlib import Path
import sys
p=Path(sys.argv[1]); d=dict(line.split('=',1) for line in (p/'state/last-check.result').read_text().splitlines())
assert 'prune' not in (p/'calls').read_text().splitlines()
assert d['pruned']=='0' and d['prune_skip']=='last-backup-not-complete'
PYPRUNE
check 'consecutive prune skips preserve the first epoch' python3 - "$TMP" <<'PYPRUNE'
from pathlib import Path
import sys
p=Path(sys.argv[1]); value=(p/'state/prune-skipped-since').read_text()
assert value.strip().isdigit() and value==(p/'first-prune-skip').read_text()
PYPRUNE
check 'incomplete hourly prune alert is raised once' test "$(grep -Fc 'check: prune skipped (last-backup-not-complete); repository keeps growing until a complete hourly backup' "$TMP/state/ALERT")" = 1
sed -i 's/^result=incomplete$/result=complete/' "$TMP/state/last-backup.result"
: > "$TMP/calls"; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'next check after a complete hourly prunes and clears skip state' python3 - "$TMP" <<'PYPRUNE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
assert 'prune' in (p/'calls').read_text().splitlines()
assert 'prune_skip=\n' in (p/'state/last-check.result').read_text()
assert not (p/'state/prune-skipped-since').exists()
PYPRUNE
export FAKE_KIND=permission
check 'first unreadable omission is incomplete' run_backup 6
rm -f "$TMP/state/ALERT"
export NOTICE=1
check 'repeated permission failure with rclone notice completes' run_backup 0
check 'unchanged unreadable set does not alert again' test ! -e "$TMP/state/ALERT"
unset NOTICE
check 'unreadable count recorded' grep -qx 'unreadable=1' "$TMP/state/last-backup.result"
check 'unreadable path appears in first alert' grep -q 'src/unreadable' "$TMP/logs/alerts.log"
export MALFORMED=1
check 'malformed JSON cannot qualify as harmless warning' run_backup 6
unset MALFORMED
check 'first omission after malformed output remains incomplete' run_backup 6
check 'known omission completes again' run_backup 0
cp "$TMP/src/unreadable" "$TMP/src/another"
export ERROR_FILE=another
check 'changed unreadable set is incomplete and alerts' run_backup 6
unset ERROR_FILE
export FAKE_RC=0
check 'clean run restores complete status' run_backup 0
export FAKE_CHECK_RC=1
: > "$TMP/calls"; rc=0; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1 || rc=$?
check 'failed check returns 5 and latches' test "$rc" = 5 -a -f "$TMP/state/CHECK_FAILED"
check 'failed check never prunes' not grep -qx prune "$TMP/calls"
check 'failed check records the prune skip and its first epoch' python3 - "$TMP/state" <<'PYPRUNE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
assert 'prune_skip=check-failed' in (p/'last-check.result').read_text()
assert (p/'prune-skipped-since').read_text().strip().isdigit()
PYPRUNE
export FAKE_CHECK_RC=0
: > "$TMP/calls"; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'failed-check latch blocks forget on following run' not grep -qx forget "$TMP/calls"
check 'passing check clears latch' test ! -e "$TMP/state/CHECK_FAILED"
check 'passing check permits prune' grep -qx 'pruned=1' "$TMP/state/last-check.result"
check 'successful prune clears skip reason and consecutive age' python3 - "$TMP/state" <<'PYPRUNE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
assert 'prune_skip=\n' in (p/'last-check.result').read_text()
assert not (p/'prune-skipped-since').exists()
PYPRUNE
check 'check precedes prune' python3 -c 'import sys;x=open(sys.argv[1]).read().splitlines();assert x.index("check")<x.index("prune")' "$TMP/calls"
echo garbage > "$TMP/state/last-backup.result"
: > "$TMP/calls"; "$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'garbled backup result blocks prune' not grep -qx prune "$TMP/calls"
# A latch uses its existing alert rather than a second incomplete-hourly alert.
rm -f "$TMP/state/ALERT" "$TMP/state/alert-seen"
echo 946684800 > "$TMP/state/SQLITE_FAILED"
"$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'latched prune skip records latch reason without a second alert' python3 - "$TMP/state" <<'PYPRUNE'
from pathlib import Path
import sys
p=Path(sys.argv[1])
assert 'prune_skip=latch' in (p/'last-check.result').read_text()
alerts=(p/'ALERT').read_text()
assert 'forget/prune SKIPPED' in alerts and 'check: prune skipped (' not in alerts
PYPRUNE
rm -f "$TMP/state/SQLITE_FAILED"

# Remote bookkeeping failures must not discard a successful backup or daily check.
export FAKE_RC=0
rm -f "$TMP/tag-count" "$TMP/list-count"
export TAG_FAILURES=1 LIST_FAIL_AT=2,3
check 'tag retries after resolver listing failure preserve success' run_backup 0
check 'tag retried once' test "$(cat "$TMP/tag-count")" = 2
check 'resolver fallback records verified complete result' grep -qx result=complete "$TMP/state/last-backup.result"
unset TAG_FAILURES LIST_FAIL_AT
check 'progress status records excluded from log' not grep -q '"message_type": "status"' "$TMP/logs/backup-$(date +%Y-%m).log"
export FAIL_SNAPSHOTS=1
: > "$TMP/calls"
"$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'retention listing failure still runs integrity check' grep -qx check "$TMP/calls"
check 'retention listing failure skips forget' not grep -qx forget "$TMP/calls"
unset FAIL_SNAPSHOTS

export FAIL_RETENTION=1
rc=0; "$REPO_DIR/backup.sh" > "$TMP/backup.out" 2>&1 || rc=$?
check 'retention preparation failure preserves backup exit success' test "$rc" = 0
unset FAIL_RETENTION
: > "$TMP/args"
"$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
check 'incomplete snapshots have bounded retention' grep -q -- '--tag incomplete --keep-within 7d' "$TMP/args"

# Promotion must wait, recover stale locks once, and verify the resulting snapshot.
reset_promotion() {
  rm -f "$TMP/tag-count" "$TMP/list-count" "$TMP/repo-lock" "$TMP/state/ALERT" "$TMP/state/alert-seen"
  rm -f "$TMP/backup-count" "$TMP"/forget-*-count "$TMP/cleanup-count"
  : > "$TMP/calls"; : > "$TMP/args"
}
run_full_backup() { local rc=0; "$REPO_DIR/backup.sh" > "$TMP/backup.out" 2>&1 || rc=$?; [[ "$rc" == "$1" ]]; }
verified_snapshot() {
  python3 - "$TMP/snapshot.json" "$TMP/state/last-backup.result" <<'PYVERIFY'
import json,sys
s=json.load(open(sys.argv[1])); result=open(sys.argv[2]).read().splitlines()
assert 'incomplete' not in s['tags'] and 'auto' in s['tags']
assert 'snapshot='+s['short_id'] in result and 'result=complete' in result
PYVERIFY
}
reset_promotion
export TAG_LOCKED=1
check 'locked promotion recovers and completes' run_backup 0
check 'promotion waits up to default 2m' grep -q '^tag --retry-lock 2m --remove incomplete --add auto abcdef12$' "$TMP/args"
check 'lock recovery runs exactly one plain unlock' test "$(grep -cx unlock "$TMP/args")" = 1
check 'unlock never removes active locks' not grep -q -- '--remove-all' "$TMP/args"
check 'lock recovery raises unlock alert' grep -q 'plain restic unlock (stale locks only) was run before retrying' "$TMP/state/ALERT"
check 'recovered snapshot verified and current ID recorded' verified_snapshot
unset TAG_LOCKED

reset_promotion
export TAG_NOOP=2
check 'successful tag no-op exits incomplete' run_full_backup 6
check 'no-op records incomplete result' grep -qx result=incomplete "$TMP/state/last-backup.result"
check 'no-op alert explains failed verification' grep -q 'could not be verified as promoted' "$TMP/state/ALERT"
check 'no-op never logs backup ok' not grep -q 'backup ok' "$TMP/backup.out"
check 'no-op never forgets' not grep -qx forget "$TMP/calls"
check 'no-op recovery unlocks only once' test "$(grep -cx unlock "$TMP/args")" = 1
unset TAG_NOOP

reset_promotion
export TAG_PARTIAL=1
check 'partial tag rewrite resolves original ID on retry' run_backup 0
check 'partial rewrite never tags stale ID again' test "$(grep -c '^tag .* abcdef12$' "$TMP/args")" = 1
check 'already promoted rewrite needs no second tag' test "$(cat "$TMP/tag-count")" = 1
check 'partial rewrite is verified and records new ID' verified_snapshot
unset TAG_PARTIAL

reset_promotion
export TAG_DUP=1
check 'duplicate rewrite with old record first resolves promoted record' run_backup 0
check 'duplicate rewrite needs only one tag call' test "$(cat "$TMP/tag-count")" = 1
check 'duplicate rewrite records verified promoted ID' verified_snapshot
unset TAG_DUP

reset_promotion
export TAG_LOCKED=2
check 'persistent repository lock exits incomplete' run_full_backup 6
check 'persistent lock recovery unlocks only once' test "$(grep -cx unlock "$TMP/args")" = 1
check 'persistent lock final alert names repository lock' grep -q 'could not promote snapshot to complete; retention skipped; repository is locked' "$TMP/state/ALERT"
check 'persistent lock skips forget' not grep -qx forget "$TMP/calls"
unset TAG_LOCKED

reset_promotion
export TAG_FAILURES=2 TAG_NETWORK=1
check 'network failure creating lock exits incomplete' run_full_backup 6
check 'network failure recovery unlocks exactly once' test "$(grep -cx unlock "$TMP/args")" = 1
check 'network failure final alert uses generic tag failure' grep -q 'could not promote snapshot to complete; retention skipped; restic tag failed rc=1' "$TMP/state/ALERT"
check 'network failure alert does not claim repository is locked' not grep -q 'repository is locked' "$TMP/state/ALERT"
unset TAG_FAILURES TAG_NETWORK

# Backup and retention share promotion's unlock budget, but retain their own retry waits.
reset_promotion
export BACKUP_LOCKED=1
check 'locked backup retries and exits successfully' run_full_backup 0
check 'backup retry completes hourly result' verified_snapshot
check 'locked backup runs exactly one plain unlock' test "$(grep -cx unlock "$TMP/args")" = 1
check 'backup lock recovery raises one alert' test "$(grep -c 'backup (auto): repository was locked; plain restic unlock' "$TMP/state/ALERT")" = 1
check 'backup retry uses identical args with lock wait' python3 - "$TMP/args" <<'PYBACKUP'
import sys
rows=[line.split() for line in open(sys.argv[1]) if line.startswith('backup ')]
assert len(rows)==2 and rows[0]==rows[1]
assert rows[0][1:3]==['--retry-lock','2m']
PYBACKUP
unset BACKUP_LOCKED

reset_promotion
export BACKUP_LOCKED=2
check 'persistent backup lock returns failure' run_full_backup 1
check 'persistent backup lock unlocks only once' test "$(grep -cx unlock "$TMP/args")" = 1
check 'persistent backup lock alerts final lock failure' grep -q 'restic backup (auto) failed rc=1; repository is locked' "$TMP/state/ALERT"
check 'persistent backup lock result is failed' grep -qx result=failed "$TMP/state/last-backup.result"
check 'persistent backup lock never forgets' not grep -qx forget "$TMP/calls"
unset BACKUP_LOCKED

reset_promotion
export BACKUP_LOCKED=1 TAG_LOCKED=1
check 'backup recovery cannot unlock again for promotion' run_full_backup 6
check 'backup and promotion share exactly one plain unlock' test "$(grep -cx unlock "$TMP/args")" = 1
check 'promotion lock after backup recovery blocks retention' not grep -qx forget "$TMP/calls"
unset BACKUP_LOCKED TAG_LOCKED

for job in backup check; do
  reset_promotion
  export FORGET_LOCKED=1
  rc=0; "$REPO_DIR/$job.sh" > "$TMP/retention.out" 2>&1 || rc=$?
  check "$job retention recovers a lock error" test "$rc" = 0
  check "$job retention uses one plain unlock total" test "$(grep -cx unlock "$TMP/args")" = 1
  check "$job retention retries each forget once with lock wait" python3 - "$TMP/args" <<'PYFORGET'
import sys
rows=[line.split() for line in open(sys.argv[1]) if line.startswith('forget ')]
assert len(rows)==6 and all(row[1:3]==['--retry-lock','2m'] for row in rows)
for tag in ('auto','quick','incomplete'):
    assert sum(row[row.index('--tag')+1]==tag for row in rows)==2
PYFORGET
  check "$job recovered forget does not alert failure" not grep -q 'forget (auto) failed' "$TMP/retention.out"
  check "$job recovery never removes active locks" not grep -q -- '--remove-all' "$TMP/args"
  unset FORGET_LOCKED
done

for job in backup check; do
  reset_promotion
  export FORGET_LOCKED=9
  [[ $job != backup ]] || export TAG_LOCKED=1
  rc=0; "$REPO_DIR/$job.sh" > "$TMP/retention.out" 2>&1 || rc=$?
  check "$job persistent forget failure preserves exit success" test "$rc" = 0
  check "$job persistent forget lock alerts failure" grep -q 'forget (auto) failed' "$TMP/state/ALERT"
  check "$job persistent forget shares one unlock across the run" test "$(grep -cx unlock "$TMP/args")" = 1
  unset FORGET_LOCKED TAG_LOCKED
done

# A legacy incomplete snapshot must lose its complete tags before retention.
reset_promotion
python3 - "$TMP/snapshot.json" <<'PYLEGACY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s['tags']=['incomplete','auto','quick']
open(p,'w').write(json.dumps(s))
PYLEGACY
export CLEANUP_LOCKED=1
rc=0; "$REPO_DIR/check.sh" > "$TMP/retention.out" 2>&1 || rc=$?
check 'retention tag cleanup retries lock error successfully' test "$rc" = 0
check 'retention cleanup waits for lock on both attempts' test "$(grep -c '^tag --retry-lock 2m --remove auto,quick ' "$TMP/args")" = 2
check 'retention cleanup removes complete tags' python3 - "$TMP/snapshot.json" <<'PYCLEAN'
import json,sys
assert json.load(open(sys.argv[1]))['tags']==['incomplete']
PYCLEAN
check 'retention cleanup shares startup unlock budget' test "$(grep -cx unlock "$TMP/args")" = 1
check 'helper removes stderr temporary files' test -z "$(find "$TMP/state" -name 'restic-error.*')"
unset CLEANUP_LOCKED

# A manual skip stays quiet; a scheduled hourly timeout is visible and deduplicated.
reset_promotion
rm -f "$TMP/skip-ready"
# shellcheck disable=SC2016 # evaluated in the child
bash -c 'exec 9>>"$1/state/backup.lock"; flock 9; touch "$1/skip-ready"; exec sleep 120' _ "$TMP" & LP=$!; CHILDREN+=("$LP")
for _ in {1..100}; do [[ -f "$TMP/skip-ready" ]] && break; sleep .05; done
echo "$(date +%s) $LP check.sh check" > "$TMP/state/lock-holder"
rc=0; "$REPO_DIR/backup.sh" > "$TMP/skip.out" 2>&1 || rc=$?
check 'busy manual backup preserves exit zero' test "$rc" = 0
check 'busy manual backup logs the skip' grep -q 'auto: another backup/check is running; skip' "$TMP/skip.out"
check 'busy manual backup creates no skip state' test ! -e "$TMP/state/backup-skipped"
check 'busy manual backup raises no alert' test ! -e "$TMP/state/ALERT"
rm -f "$TMP/state/backup-skipped" "$TMP/state/ALERT" "$TMP/state/alert-seen"
for _ in 1 2; do
  rc=0; "$REPO_DIR/backup.sh" --wait 1 > "$TMP/skip.out" 2>&1 || rc=$?
  check 'busy hourly backup preserves exit zero' test "$rc" = 0
done
check 'hourly lock skip records operator state' python3 - "$TMP/state/backup-skipped" <<'PYSKIP'
import sys
d=dict(line.strip().split('=',1) for line in open(sys.argv[1]))
assert d['time'].isdigit()
assert {k:d[k] for k in ('mode','reason','holder','waited')}==dict(mode='auto',reason='lock-busy',holder='check.sh',waited='1')
PYSKIP
check 'hourly skip alert is raised exactly once' test "$(grep -Fc 'hourly backup skipped: backup lock still busy after waiting 1s (held by check.sh); no hourly snapshot was taken this slot' "$TMP/state/ALERT")" = 1
rm -f "$TMP/state/backup-skipped" "$TMP/state/ALERT" "$TMP/state/alert-seen"
rc=0; "$REPO_DIR/backup.sh" --quick > "$TMP/skip.out" 2>&1 || rc=$?
check 'busy quick backup preserves exit zero' test "$rc" = 0
check 'busy quick backup creates no skip state or alert' not test -e "$TMP/state/backup-skipped" -o -e "$TMP/state/ALERT"
"$REPO_DIR/backup.sh" --wait 1 > "$TMP/skip.out" 2>&1
kill "$LP"; wait "$LP" 2>/dev/null || true; CHILDREN=()
check 'hourly succeeds once lock is free' run_full_backup 0
check 'successful hourly clears skip state' test ! -e "$TMP/state/backup-skipped"

leftovers=("$TMP/state"/{snapshot-list,promote-list,promote-error,promote-tag}.fixture)
touch "${leftovers[@]}"
check 'backup sweeps abandoned promotion and listing files' run_backup 0
check 'all abandoned temporary files are gone' python3 - "${leftovers[@]}" <<'PYLEFTOVERS'
import os,sys
assert not any(os.path.exists(path) for path in sys.argv[1:])
PYLEFTOVERS
touch "${leftovers[@]}"
rc=0; "$REPO_DIR/backup.sh" --dry-run > "$TMP/backup.out" 2>&1 || rc=$?
check 'dry-run with abandoned temporary files succeeds' test "$rc" = 0
check 'dry-run preserves all abandoned temporary files' python3 - "${leftovers[@]}" <<'PYLEFTOVERS'
import os,sys
assert all(os.path.exists(path) for path in sys.argv[1:])
PYLEFTOVERS

reset_promotion
export LIST_FAILURES=1
check 'transient listing failure retries and backup proceeds' run_backup 0
check 'retry truncates partial JSON output' not grep -q 'discard this partial output' "$TMP/state/snapshots.json"
unset LIST_FAILURES
for style in locked plain; do
  reset_promotion
  export FAIL_SNAPSHOTS=1
  [[ $style != locked ]] || export LIST_LOCKED=1
  check "$style pre-listing failure exits 7" run_backup 7
  check "$style pre-listing failure retries exactly once" test "$(cat "$TMP/list-count")" = 2
  if [[ $style == locked ]]; then
    check 'pre-listing lock alert identifies repository lock' grep -q 'repository is locked (stale lock?) so snapshots could not be listed' "$TMP/state/ALERT"
  else check 'plain pre-listing failure retains Drive/auth alert' grep -q 'Drive/auth problem?' "$TMP/state/ALERT"; fi
  check "$style pre-listing failure never runs backup" not grep -qx backup "$TMP/calls"
  unset FAIL_SNAPSHOTS LIST_LOCKED
done

reset_promotion
export FAIL_SNAPSHOTS=1 LIST_RC=124
check 'timed-out pre-listing exits 7' run_backup 7
check 'timed-out pre-listing is not retried' test "$(cat "$TMP/list-count")" = 1
unset FAIL_SNAPSHOTS LIST_RC

reset_promotion
check 'complete backup with retention succeeds' run_full_backup 0
"$REPO_DIR/status.sh" > "$TMP/status.out" 2>&1
"$REPO_DIR/report.sh" --no-upload > "$TMP/report.out" 2>&1
"$REPO_DIR/restore.sh" list > "$TMP/restore-list.out" 2>&1
"$REPO_DIR/restore.sh" ls latest > "$TMP/restore-ls.out" 2>&1
"$REPO_DIR/check.sh" > "$TMP/check.out" 2>&1
"$REPO_DIR/test-restore.sh" > "$TMP/test-restore.out" 2>&1
check 'all read-only listings use no-lock and writes do not' python3 - "$TMP/args" <<'PYARGS'
import sys
calls=[l.split() for l in open(sys.argv[1])]
for cmd in ('snapshots','stats','ls'):
    rows=[a for a in calls if a[0]==cmd]
    assert rows and all('--no-lock' in a for a in rows), (cmd,rows)
for cmd in ('tag','backup','unlock','forget','prune','check','restore'):
    assert all('--no-lock' not in a for a in calls if a[0]==cmd), cmd
assert ['unlock'] in calls
PYARGS
month_log="$TMP/logs/backup-$(date +%Y-%m).log"
check 'restic log identifies backup caller PID and command' grep -Eq 'restic call: caller=backup.sh:main pid=[0-9]+ ppid=[0-9]+ wrapper=R cmd=backup ' "$month_log"
check 'forget logs RT wrapper' grep -Eq 'restic call: .*wrapper=RT cmd=forget ' "$month_log"
check 'restic call log excludes transport options and password text' not grep -E 'restic call:.*(-o rclone|restic-pass|synthetic test fixture|RESTIC_PASSWORD)' "$month_log"
check 'promotion temporary files are removed' test -z "$(find "$TMP/state" -maxdepth 1 -name 'promote-*' -o -name 'snapshot-list.*')"

# Logging also preserves stdout and status when the log cannot be opened.
# shellcheck disable=SC2016 # evaluated in the child
bash -c 'source "$1/lib.sh"; LOG="$TEST_ROOT/no-dir/log"; R stats --no-lock --json; RT forget; R check' _ "$REPO_DIR" > "$TMP/wrappers.out" 2> "$TMP/wrappers.err"
check 'unwritable log preserves restic stdout' grep -qx '{"total_size": 42}' "$TMP/wrappers.out"
check 'unwritable log does not leak diagnostics' test ! -s "$TMP/wrappers.err"

# Read-only restic processes and tag must be visible while the backup flock is held.
for subcommand in tag snapshots stats; do
  touch "$TMP/restic-wait"; rm -f "$TMP/restic-ready" "$TMP/status-lock-ready"
  RESTIC_SLEEP=1 "$TMP/bin/restic" -o x "$subcommand" --fixture & RP=$!; CHILDREN+=("$RP")
  # shellcheck disable=SC2016 # evaluated in the child
  bash -c 'exec 9>>"$1/state/backup.lock"; flock 9; touch "$1/status-lock-ready"; exec sleep 120' _ "$TMP" & LP=$!; CHILDREN+=("$LP")
  for _ in {1..100}; do [[ -e "$TMP/restic-ready" && -e "$TMP/status-lock-ready" ]] && break; sleep .05; done
  "$REPO_DIR/status.sh" --local > "$TMP/status.out" 2>&1
  check "status detects running restic $subcommand" grep -q "Running now: restic pid $RP " "$TMP/status.out"
  rm -f "$TMP/restic-wait"; wait "$RP"
  kill "$LP"; wait "$LP" 2>/dev/null || true; CHILDREN=()
done

# Execute the restart handoff's stop branch under errexit with a refused stop.
python3 - "$REPO_DIR/install.sh" > "$TMP/handoff.sh" <<'PYHANDOFF'
import sys
s=open(sys.argv[1]).read()
print('set -Eeuo pipefail')
print('sched_pid() { echo 123; }; python3() { return 1; }; log() { echo "$*"; }')
print(s[s.index('    p=$(sched_pid)'):s.index('    sleep 2; flock -u 9')])
print('echo handoff-continued')
PYHANDOFF
bash "$TMP/handoff.sh" "$REPO_DIR" "$TMP/state" > "$TMP/handoff.out"
check 'refused stop still continues restart handoff' grep -qx handoff-continued "$TMP/handoff.out"
check 'refused stop logged' grep -q 'stop refused' "$TMP/handoff.out"

check 'missing pidfd support fails clearly without signalling' python3 - "$REPO_DIR/lock-control.py" <<'PYNOPIDFD'
import contextlib, io, os, runpy, sys
from unittest.mock import patch
path=sys.argv[1]
err=io.StringIO()
original=os.pidfd_open
del os.pidfd_open
try:
    with patch.object(sys,'argv',[path,'stop','unused','424242']), contextlib.redirect_stderr(err):
        try: runpy.run_path(path,run_name='__main__')
        except SystemExit as exc: assert exc.code == 1
        else: raise AssertionError('stop succeeded without pidfd')
    assert 'pidfd support is required' in err.getvalue()
finally:
    os.pidfd_open=original
PYNOPIDFD

# Simulate a holder appearing after the process-table snapshot without signalling real PIDs.
check 'force reports late inherited holders instead of success' python3 - "$REPO_DIR/lock-control.py" <<'PYLATE'
import importlib.util, sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('locks',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Poll:
    def register(self, *args): pass
    def poll(self, *args): return [(42, 1)]
with patch.object(m,'processes',return_value={424242:(0,424242,'start')}), \
     patch.object(m,'holds',return_value=True), \
     patch.object(m,'holders',return_value=[424243]), \
     patch.object(m.os,'pidfd_open',return_value=42), \
     patch.object(m.os,'close'), \
     patch.object(m.signal,'pidfd_send_signal'), \
     patch('select.poll',return_value=Poll()), \
     patch.object(m.time,'monotonic',side_effect=[0,0,0,3]):
    try: m.force('unused')
    except RuntimeError as exc: assert '424243' in str(exc)
    else: raise AssertionError('late holder ignored')
PYLATE

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

if [[ -x "$REPO_DIR/bin/restic" ]]; then
  cp "$TMP/test.env" "$TMP/real.env"
  printf '\nGB_BIN="%s/bin"\nexport RESTIC_REPOSITORY="%s/timed-repo"\n' "$REPO_DIR" "$TMP" >> "$TMP/real.env"
  RESTIC_PASSWORD_FILE="$TMP/fixture/restic-pass" "$REPO_DIR/bin/restic" -r "$TMP/timed-repo" init > "$TMP/real.out" 2>&1
  started=$SECONDS
  GB_CONFIG="$TMP/real.env" "$REPO_DIR/backup.sh" --no-forget > "$TMP/timed.out" 2>&1
  lines=$(wc -l < "$TMP/logs/backup-$(date +%Y-%m).log")
  echo "  real backup.sh elapsed=$((SECONDS-started))s cumulative_log_lines=$lines"
  check 'real backup summary retained in log' grep -q '"message_type":"summary"' "$TMP/logs/backup-$(date +%Y-%m).log"
  check 'real backup progress absent from log' not grep -Eq '"message_type": *"status"' "$TMP/logs/backup-$(date +%Y-%m).log"
else echo '  skip - real restic checks (bin/restic unavailable)'; fi

# Real local restic JSON: permission errors are classified from actual output too.
if [[ $(id -u) != 0 && -x "$REPO_DIR/bin/restic" ]]; then
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
