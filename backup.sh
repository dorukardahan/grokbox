#!/usr/bin/env bash
# Time-Machine-style snapshot of the backup roots to restic (default: Google Drive via rclone).
#   backup.sh                hourly snapshot, tag `auto` (+ brain export, SQLite copies, forget)
#   backup.sh --quick        quick snapshot, tag `quick` (same roots/excludes; unchanged files are
#                            only stat'ed). Never waits: skips if any other backup/check holds the lock.
# Flags: --dry-run (no upload, no lock), --force "reason" (bypass stale guard once), --no-forget,
#        --wait SECONDS (hourly only: wait for a running quick snapshot to finish, default 0)
# Exit codes: 0 ok/skipped, 3 missing credentials, 4 stale-computer guard tripped, 6 incomplete snapshot
# (kept, alert raised, no baseline/last-success update, no forget), 7 repo unreachable.
source "$(dirname "$0")/lib.sh"
DRY=0; FORCE=""; FORGET=1; MODE=auto; WAIT=0
while [[ $# -gt 0 ]]; do case "$1" in
  --dry-run) DRY=1;; --force) FORCE="${2:?reason required}"; shift;; --no-forget) FORGET=0;;
  --quick) MODE=quick;; --wait) WAIT="${2:?seconds}"; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; shift; done
[[ $MODE == quick ]] && WAIT=0
if [[ $DRY == 1 ]]; then   # private temp files: a dry run never touches shared state
  DRY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/grokbox-dry.XXXXXX"); trap 'rm -rf "$DRY_TMP"' EXIT
  EXCL_FILE="$DRY_TMP/excludes.combined"
else
  exec 9>"$GB_STATE/backup.lock"
  if ! flock -w "$WAIT" 9; then log "$MODE: another backup/check is running; skip"; exit 0; fi
  need_creds
fi
ROOTS=("${BACKUP_ROOTS[@]}"); [[ $MODE == quick ]] && ROOTS=("${QUICK_ROOTS[@]}")
mapfile -t PATHS < <(backup_paths "${ROOTS[@]}")

# --- guard 0: box just booted / still hydrating files from storage -> skip quietly
box_ready || exit 0

# --- guard 1: stale-computer guard (file set suddenly shrank or went back in time)
# Hourly and quick both run it; it compares with the latest HOURLY snapshot (tag auto), whose tags
# carry files/bytes/newest. A trip writes state/ALERT and uploads nothing.
cur="$GB_STATE/manifest-$MODE.json"; [[ $DRY == 1 ]] && cur="$DRY_TMP/manifest.json"
manifest "${PATHS[@]}" > "$cur"
prev="$GB_STATE/manifest-last-good.json"
remote_prev="$GB_STATE/manifest-remote.json"
PARENT=()
if [[ $DRY == 0 ]]; then   # prefer the repo's last snapshot (local state may itself be rolled back)
  if R snapshots --host "$BACKUP_HOST" --json > "$GB_STATE/snapshots.json.tmp" 2>>"$LOG"; then
    mv "$GB_STATE/snapshots.json.tmp" "$GB_STATE/snapshots.json"
    rm -f "$remote_prev"
    python3 - "$GB_STATE/snapshots.json" > "$remote_prev" <<'PY' || true
import json,sys
s=[x for x in json.load(open(sys.argv[1])) if "auto" in (x.get("tags") or []) and "incomplete" not in (x.get("tags") or [])]
s.sort(key=lambda x: x["time"])
if s:
  t={k:v for k,v in (x.split("=",1) for x in s[-1].get("tags",[]) if "=" in x)}
  if "files" in t: print(json.dumps({"files":int(t["files"]),"bytes":int(t["bytes"]),"newest_mtime":int(t["newest"]),"snapshot":s[-1]["short_id"],"time":s[-1]["time"]}))
PY
    [[ -s "$remote_prev" ]] && prev="$remote_prev"
    # Explicit parent = newest snapshot of this tag with the same paths, so hourly and quick chains
    # never force each other to re-read everything.
    pid=$(python3 - "$GB_STATE/snapshots.json" "$MODE" "${PATHS[@]}" <<'PY'
import json,sys
mode=sys.argv[2]; roots=sorted(sys.argv[3:])
s=[x for x in json.load(open(sys.argv[1])) if mode in (x.get("tags") or []) and "incomplete" not in (x.get("tags") or []) and sorted(x.get("paths") or [])==roots]
s.sort(key=lambda x: x["time"])
print(s[-1]["id"] if s else "")
PY
)
    [[ -n "$pid" ]] && PARENT=(--parent "$pid")
  else
    rm -f "$GB_STATE/snapshots.json.tmp"
    alert "$MODE: cannot list snapshots on $RESTIC_REPOSITORY (Drive/auth problem?); backup NOT run"; exit 7
  fi
fi
verdict=$(python3 - "$cur" "$prev" "$GUARD_MAX_DROP_PCT" "$GUARD_MTIME_BACK_HOURS" <<'PY'
import json,sys,os
cur=json.load(open(sys.argv[1])); p=sys.argv[2]; drop=float(sys.argv[3]); back=float(sys.argv[4])*3600
if not os.path.exists(p) or os.path.getsize(p)==0: print("OK first-run"); sys.exit()
prev=json.load(open(p)); bad=[]
for k in ("files","bytes"):
  if prev.get(k) and cur[k] < prev[k]*(1-drop/100): bad.append(f"{k} {prev[k]} -> {cur[k]} (-{100-100*cur[k]/prev[k]:.0f}%)")
if prev.get("newest_mtime") and cur["newest_mtime"] < prev["newest_mtime"]-back:
  bad.append(f"newest file went back in time by {(prev['newest_mtime']-cur['newest_mtime'])/3600:.1f}h")
print("STALE "+"; ".join(bad) if bad else "OK")
PY
)
if [[ "$verdict" == STALE* ]]; then
  if [[ -n "$FORCE" ]]; then log "guard overridden ($verdict) reason: $FORCE"
  elif [[ $DRY == 1 ]]; then log "dry-run ($MODE): stale guard WOULD trip: ${verdict#STALE }"; exit 4
  else
    echo "$(date +%s) $MODE ${verdict#STALE }" > "$GUARD_LATCH"   # blocks forget/prune until a good hourly backup
    alert "STALE-COMPUTER GUARD tripped ($MODE), backup ABORTED: ${verdict#STALE }. Nothing was uploaded and no old snapshot was touched; forget/prune are blocked until a successful hourly backup. Compare with 'restore.sh ls latest'; if the change is intentional run: backup.sh --force \"why\""; exit 4; fi
fi

if [[ $DRY == 1 ]]; then
  read -r F B < <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["files"],d["bytes"])' "$cur")
  log "dry-run ($MODE): would back up files=$F bytes=$B (manifest estimate; guard verdict: $verdict)"; exit 0; fi

# --- consistent copies of live SQLite databases + brain export (at most hourly)
# The staged list is written atomically by the script at the end of each run and lists only databases
# whose fresh copy succeeded; removing it first means a timeout/crash falls back to the live files.
NO_FORGET_WHY=""
rm -f "$GB_STATE/sqlite-staged.txt"
timeout 900 python3 "$GB_DIR/sqlite-snapshot.py" "$GB_STAGING" "$GB_STATE/sqlite-staged.txt" "${SQLITE_GLOBS[@]}" 2>>"$LOG" \
  || { alert "sqlite snapshot failed or timed out (see $LOG); databases without a fresh copy are backed up live; forget skipped"; NO_FORGET_WHY="sqlite snapshot failed"; date +%s > "$SQLITE_LATCH"; }
BRAIN_ARGS=(); for d in "${BRAIN_AGENT_DIRS[@]}"; do BRAIN_ARGS+=(--agent-dir "$d"); done
for r in "${BACKUP_ROOTS[@]}"; do BRAIN_ARGS+=(--root "$r"); done
timeout 900 python3 "$GB_DIR/brain-export.py" "$GB_STAGING" --min-interval-min "$BRAIN_EXPORT_MIN_INTERVAL_MIN" \
  --stores-glob "$STORES_GLOB" --staged-list "$GB_STATE/sqlite-staged.txt" --max-file-mb "$BRAIN_MAX_FILE_MB" "${BRAIN_ARGS[@]}" 2>>"$LOG" \
  || alert "brain export failed (see $LOG); snapshot continues without a fresh export"
# tool inventory (installed CLIs, venv freezes) refreshed at most daily (hourly runs only)
inv="$GB_STATE/rebuild-kit/inventory.txt"
if [[ $MODE == auto ]] && [[ ! -f "$inv" || -n "$(find "$inv" -mmin +1440)" ]]; then
  timeout 900 bash "$GB_DIR/rebuild-kit/inventory.sh" >/dev/null 2>>"$LOG" || log "WARN inventory refresh failed"; fi

exclude_args
read -r F B N < <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["files"],d["bytes"],d["newest_mtime"])' "$cur")
TAGS=(--tag "$MODE" --tag "profile=$BACKUP_PROFILE" --tag "files=$F" --tag "bytes=$B" --tag "newest=$N")
log "backup start mode=$MODE profile=$BACKUP_PROFILE files=$F bytes=$B parent=${PARENT[1]:-none}"
rc=0   # `|| rc=$?` keeps both errexit and the ERR trap quiet for restic's rc=3 (partial but valid snapshot)
R backup --host "$BACKUP_HOST" --one-file-system --compression auto "${PARENT[@]}" "${EXARGS[@]}" "${TAGS[@]}" \
  "${PATHS[@]}" >>"$LOG" 2>&1 || rc=$?
# restic: 0 ok, 3 = snapshot created but some files unreadable (still a good snapshot)
if [[ $rc != 0 && $rc != 3 ]]; then alert "restic backup ($MODE) failed rc=$rc (see $LOG)"; exit "$rc"; fi
if [[ $rc == 3 ]]; then   # snapshot exists but is incomplete: keep it, do not treat it as a good baseline
  date +%s > "$GB_STATE/last-partial"
  inc=$(R snapshots --host "$BACKUP_HOST" --tag "$MODE" --latest 1 --json 2>>"$LOG" \
        | python3 -c 'import json,sys;s=sorted(json.load(sys.stdin),key=lambda x:x["time"]);print(s[-1]["id"] if s else "")' 2>>"$LOG" || true)
  if [[ -n "$inc" ]] && R tag --add incomplete "$inc" >>"$LOG" 2>&1; then :
  else alert "could not tag the incomplete snapshot ${inc:0:8}; the guard baseline may use it until it is tagged 'incomplete' by hand"; fi
  alert "restic backup ($MODE) created an INCOMPLETE snapshot (some files unreadable, see $LOG); last-success and the guard baseline were NOT updated, forget skipped"
  exit 6
fi
date +%s > "$GB_STATE/last-success-$MODE"
if [[ $MODE == auto ]]; then
  cp "$cur" "$GB_STATE/manifest-last-good.json"; date +%s > "$GB_STATE/last-success"
  rm -f "$GUARD_LATCH" "$GB_STATE/last-partial"   # only a good hourly backup clears the latch
  [[ -z "$NO_FORGET_WHY" ]] && rm -f "$SQLITE_LATCH"   # ...and the SQLite latch needs a fully clean hourly
fi
log "backup ok mode=$MODE rc=$rc"
if [[ -n "$NO_FORGET_WHY" ]]; then log "forget skipped: $NO_FORGET_WHY"
elif [[ -e "$GUARD_LATCH" ]]; then alert "forget skipped: stale guard latch ($GUARD_LATCH) is set"
elif [[ -e "$SQLITE_LATCH" ]]; then alert "forget skipped: SQLite staging failed earlier ($SQLITE_LATCH is set; clears after a fully successful hourly backup)"
elif [[ $FORGET == 1 && $MODE == auto ]]; then   # forget only; the actual prune happens daily in check.sh
  R forget --host "$BACKUP_HOST" --tag auto "${KEEP[@]}" >>"$LOG" 2>&1 || alert "forget (auto) failed"
  R forget --host "$BACKUP_HOST" --tag quick "${KEEP_QUICK[@]}" >>"$LOG" 2>&1 || alert "forget (quick) failed"
fi
exit 0
