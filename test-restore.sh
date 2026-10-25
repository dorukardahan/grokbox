#!/usr/bin/env bash
# Real test restore: pulls a sample out of a snapshot into a private (chmod 700) $RESTORE_BASE/restore-test-<date>/,
# verifies every restored file against the snapshot's own metadata and, where the live file is unchanged since
# the snapshot (same size + mtime), against the live file's SHA-256. Then deletes the restore dir (trap).
#   test-restore.sh [--weekly] [SNAPSHOT]     default: latest hourly (tag auto) snapshot
# Sample: critical files first (the config file, TEST_RESTORE_PATHS, the staged brain + server exports and
# SQLite copies, if in the snapshot), plus TEST_RESTORE_RANDOM_FILES random files (< 64 MB) from anywhere.
# --weekly: run by scheduler.sh once per week (TEST_RESTORE_WEEKDAY / TEST_RESTORE_AT); same checks.
# Result: state/test-restore.result (result=ok|failed, time, files, mismatches), state/test-restore-result.txt,
# state/last-test-restore on success; any failure -> state/ALERT. Exit 75 = backup lock busy (scheduler retries).
source "$(dirname "$0")/lib.sh"; need_creds
WEEKLY=0; SNAP=""
for a in "$@"; do case "$a" in --weekly) WEEKLY=1;; -h|--help) sed -n 2,10p "$0"; exit 0;; *) SNAP="$a";; esac; done
MODE=$([[ $WEEKLY == 1 ]] && echo weekly || echo once)
RESULT="$GB_STATE/test-restore.result"
fail() {  # fail MESSAGE [files] [mismatches]: alert, record the failure, exit 6 (the trap removes the restore dir)
  alert "TEST RESTORE FAILED ($MODE): $1"
  kv_write "$RESULT" "result=failed" "time=$(date +%s)" "files=${2:-0}" "mismatches=${3:-0}" "snapshot=${SNAP:0:8}"
  exit 6; }
if [[ "${GB_LOCK_HELD:-0}" != 1 ]]; then
  exec 9>"$GB_STATE/backup.lock"
  flock -w "${LOCK_WAIT:-3600}" 9 || { log "test-restore ($MODE): backup lock busy; not run now"; exit 75; }
  took_lock test-restore "$MODE"
fi
if [[ -z "$SNAP" ]]; then
  SNAP=$(R snapshots --host "$BACKUP_HOST" --tag auto --json 2>>"$LOG" | python3 -c 'import json,sys;s=sorted(json.load(sys.stdin),key=lambda x:x["time"]);print(s[-1]["id"] if s else "")')
  [[ -n "$SNAP" ]] || { log "test-restore: no hourly snapshot yet; nothing to test"; exit 0; }
fi
mkdir -p "$RESTORE_BASE"
T="$RESTORE_BASE/restore-test-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$T"; chmod 700 "$T"   # private: restored data may be sensitive
work=$(mktemp -d); chmod 700 "$work"; trap 'rm -rf "$work" "$T"' EXIT
log "test-restore ($MODE): snapshot ${SNAP:0:8} -> $T"
# full listing of the snapshot (JSON lines) -> critical paths + random small files
R ls --json "$SNAP" > "$work/ls.jsonl" 2>>"$LOG"
python3 - "$work/ls.jsonl" "${TEST_RESTORE_RANDOM_FILES:-25}" "$GB_CONFIG" "$GB_STAGING/brain" "$GB_STAGING/server-export" "$GB_STAGING/sqlite" "${TEST_RESTORE_PATHS[@]}" > "$work/includes.txt" <<'PY'
import json,sys,random
files=[]; known=set()
fixed=sys.argv[3:]
for l in open(sys.argv[1]):
    try: n=json.loads(l)
    except ValueError: continue
    p=n.get("path","")
    if n.get("struct_type")!="node": continue
    known.add(p)
    if n.get("type")=="file" and 0 < n.get("size",0) < 64*2**20 and not any(p==f or p.startswith(f.rstrip("/")+"/") for f in fixed) \
       and not any(c in p for c in "[]*?\\\n"):
        files.append(p)   # glob metacharacters would be read as patterns by --include-file
random.shuffle(files)
for f in fixed:
    if f in known: print(f)
for p in files[:int(sys.argv[2])]: print(p)
PY
if [[ ! -s "$work/includes.txt" ]]; then fail "nothing in snapshot ${SNAP:0:8} to sample (empty snapshot?)"; fi
R restore "$SNAP" --target "$T" --include-file "$work/includes.txt" --verify >>"$LOG" 2>&1 \
  || fail "restic restore of ${SNAP:0:8} returned an error (see $LOG)"
res=$(python3 - "$work/ls.jsonl" "$work/includes.txt" "$T" <<'PY'
import json,sys,os,hashlib,re
meta={}
for l in open(sys.argv[1]):
    try: n=json.loads(l)
    except ValueError: continue
    if n.get("struct_type")=="node" and n.get("type")=="file": meta[n["path"]]=n
inc=[l.strip() for l in open(sys.argv[2]) if l.strip()]; T=sys.argv[3]
def want(p): return any(p==i or p.startswith(i.rstrip("/")+"/") for i in inc)
def h(p):
    d=hashlib.sha256()
    with open(p,"rb") as f:
        for b in iter(lambda:f.read(1<<20),b""): d.update(b)
    return d.hexdigest()
from datetime import datetime
c=dict(expected=0,restored=0,size_ok=0,hash_equal_live=0,live_changed=0,live_missing=0,missing=0,bad=0); bad=[]
for p,n in meta.items():
    if not want(p): continue
    c["expected"]+=1; r=T+p
    if not os.path.isfile(r): c["missing"]+=1; bad.append("not restored: "+p); continue
    c["restored"]+=1
    if os.path.getsize(r)!=n.get("size",0): c["bad"]+=1; bad.append("size differs from snapshot: "+p); continue
    c["size_ok"]+=1
    if not os.path.isfile(p): c["live_missing"]+=1; continue
    st=os.stat(p); m=datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", n["mtime"]).replace("Z","+00:00")).timestamp()
    if st.st_size!=n["size"] or abs(st.st_mtime-m)>1e-3: c["live_changed"]+=1; continue
    if h(r)==h(p): c["hash_equal_live"]+=1
    else: c["bad"]+=1; bad.append("content differs from unchanged live file: "+p)
print(json.dumps(c)); [print("BAD", b) for b in bad[:20]]
PY
) || fail "verification script error"
summary=$(head -1 <<<"$res")
{ echo "$(date '+%F %T %Z') snapshot ${SNAP:0:8} ($MODE)"; echo "$res"; } > "$GB_STATE/test-restore-result.txt"
log "test-restore result: $summary"
read -r ok files mism < <(python3 -c 'import json,sys;c=json.loads(sys.argv[1]);print(int(c["missing"]==0 and c["bad"]==0 and c["restored"]>0),c["restored"],c["missing"]+c["bad"])' "$summary")
if [[ $ok == 1 ]]; then
  date +%s > "$GB_STATE/last-test-restore"
  kv_write "$RESULT" "result=ok" "time=$(date +%s)" "files=$files" "mismatches=0" "snapshot=${SNAP:0:8}"
  log "test restore OK ($MODE, $files files verified; restore dir removed)"
else fail "${SNAP:0:8}: $summary (details: state/test-restore-result.txt)" "$files" "$mism"; fi
