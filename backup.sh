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
  if ! flock -w "$WAIT" 9; then
    problem=$(lock_problem); [[ -z "$problem" ]] || alert "$problem"
    if [[ $MODE == auto ]]; then
      holder=unknown
      if lock_record; then holder="${LOCK_JOB:-unknown}"; fi
      printf 'time=%s\nmode=auto\nreason=lock-busy\nholder=%s\nwaited=%s\n' "$(date +%s)" "$holder" "$WAIT" > "$GB_STATE/backup-skipped"
      alert "hourly backup skipped: backup lock still busy after waiting ${WAIT}s (held by $holder); no hourly snapshot was taken this slot"
    fi
    log "$MODE: another backup/check is running; skip"; exit 0; fi
  rm -f "$GB_STATE"/snapshot-list.* "$GB_STATE"/promote-list.* "$GB_STATE"/promote-error.* "$GB_STATE"/promote-tag.*
  took_lock "$MODE"
  if [[ $MODE == auto ]]; then
    STARTED=$(date +%s); RESULT=failed; SNAPSHOT=""; FILES=0; BYTES=0; ADDED=0; UNREADABLE=0
    # shellcheck disable=SC2329 # invoked by EXIT trap
    write_backup_result() {
      printf 'result=%s\ntime=%s\nsnapshot=%s\nfiles=%s\nbytes=%s\nadded=%s\nduration_s=%s\nunreadable=%s\n' \
        "$RESULT" "$(date +%s)" "${SNAPSHOT:0:8}" "$FILES" "$BYTES" "$ADDED" "$(( $(date +%s) - STARTED ))" "$UNREADABLE" \
        > "$GB_STATE/last-backup.result.tmp"
      mv "$GB_STATE/last-backup.result.tmp" "$GB_STATE/last-backup.result"
    }
    trap write_backup_result EXIT
    write_backup_result  # a hard kill must not leave the previous complete result authorizing prune
  fi
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
  list_err=$(mktemp "$GB_STATE/snapshot-list.XXXXXX")
  if snapshot_list "$GB_STATE/snapshots.json.tmp" "$list_err" --host "$BACKUP_HOST" --json; then
    rm -f "$list_err"
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
    if restic_lock_error "$list_err"; then
      alert "$MODE: repository is locked (stale lock?) so snapshots could not be listed; backup NOT run"
    else alert "$MODE: cannot list snapshots on $RESTIC_REPOSITORY (Drive/auth problem?); backup NOT run"; fi
    rm -f "$list_err"; exit 7
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
TAGS=(--tag incomplete --tag "profile=$BACKUP_PROFILE" --tag "files=$F" --tag "bytes=$B" --tag "newest=$N")
log "backup start mode=$MODE profile=$BACKUP_PROFILE files=$F bytes=$B parent=${PARENT[1]:-none}"
rc=0   # `|| rc=$?` keeps both errexit and the ERR trap quiet for restic's rc=3 (partial but valid snapshot)
events="$GB_LOGS/backup-$MODE.json.tmp"
for attempt in 1 2; do
  rc=0
  BACKUP_STARTED=$(date +%s)
  RESTIC_PROGRESS_FPS=0.01 R_TIMEOUT="$RESTIC_TIMEOUT_BACKUP" R backup --retry-lock "$LOCK_RETRY_WAIT" --json --host "$BACKUP_HOST" --one-file-system --compression auto "${PARENT[@]}" "${EXARGS[@]}" "${TAGS[@]}" \
    "${PATHS[@]}" >"$events" 2>&1 || rc=$?
  if [[ $attempt == 1 && $rc != 0 && $GB_UNLOCK_DONE == 0 ]] && restic_lock_error "$events"; then
    cat "$events" >>"$LOG"
    restic_unlock_once "backup ($MODE)"
  else break; fi
done
backup_locked=0; restic_lock_error "$events" && backup_locked=1
python3 - "$events" >> "$LOG" <<'PYLOG'
import json, sys
for line in open(sys.argv[1]):
    try:
        entry = json.loads(line)
    except ValueError:
        entry = {}
    if not isinstance(entry, dict) or entry.get('message_type') != 'status':
        sys.stdout.write(line)
PYLOG
mapfile -t summary < <(python3 "$GB_DIR/backup-result.py" "$events" "$GB_STATE/unreadable-$MODE.json")
SNAPSHOT="${summary[1]:-}"; FILES="${summary[2]:-0}"; BYTES="${summary[3]:-0}"; ADDED="${summary[4]:-0}"; UNREADABLE="${summary[5]:-0}"
rm -f "$events"
if [[ $rc == 124 || $rc == 137 ]]; then
  RESULT=timeout
  outcome="TIMED OUT"; ending="timed out and terminated"
  if [[ $rc == 137 ]]; then
    outcome="INTERRUPTED"
    budget=$(python3 - "$RESTIC_TIMEOUT_BACKUP" <<'PYTIME'
import re, sys
m = re.fullmatch(r'(\d+(?:\.\d+)?)([smhd]?)', sys.argv[1])
print(float(m[1]) * {'':1, 's':1, 'm':60, 'h':3600, 'd':86400}[m[2]] if m else 0)
PYTIME
)
    ending="killed after timeout elapsed (possibly termination grace or external SIGKILL)"
    if python3 - "$budget" "$(( $(date +%s) - BACKUP_STARTED ))" <<'PYTIME'
import sys
sys.exit(0 if float(sys.argv[1]) == 0 or float(sys.argv[2]) < float(sys.argv[1]) else 1)
PYTIME
    then ending="killed before the timeout elapsed (possible OOM or external SIGKILL)"; fi
  fi
  alert "restic backup ($MODE) $outcome (timeout limit $RESTIC_TIMEOUT_BACKUP): $ending (rc=$rc); interrupted uploads resume next run; prune waits for a complete hourly backup"
  exit "$rc"
fi
if [[ $rc != 0 && $rc != 3 ]]; then
  failure=""; [[ $backup_locked == 0 ]] || failure="; repository is locked"
  alert "restic backup ($MODE) failed rc=$rc$failure (see $LOG)"; exit "$rc"
fi
if [[ $rc == 3 && "${summary[0]:-}" != warnings ]]; then
  RESULT=incomplete; date +%s > "$GB_STATE/last-partial"
  alert "restic backup ($MODE) created an INCOMPLETE snapshot; excluded from complete-snapshot retention (kept for 7 days); last-success unchanged. Unreadable paths (up to 20): ${summary[6]:-unknown; see log}"
  exit 6
fi
# A tag rewrite changes the ID; resolve against the backup ID and its original field each time.
backup_id="$SNAPSHOT"
promote_list=$(mktemp "$GB_STATE/promote-list.XXXXXX")
promote_err=$(mktemp "$GB_STATE/promote-error.XXXXXX")
tag_out=$(mktemp "$GB_STATE/promote-tag.XXXXXX")
resolve_promotion() {
  snapshot_list "$promote_list" "$promote_err" --host "$BACKUP_HOST" --json || return 1
  python3 - "$promote_list" "$backup_id" "$MODE" 2>>"$LOG" <<'PYPROMOTE'
import json,sys
snaps=json.load(open(sys.argv[1])); anchor=sys.argv[2]; mode=sys.argv[3]
def matches(value):
    return bool(value and anchor) and (value.startswith(anchor) or anchor.startswith(value))
selected=None; best=3
for snap in snaps:
    if matches(snap.get("id")) or matches(snap.get("original")):
        tags=snap.get("tags") or []
        rank=0 if mode in tags and "incomplete" not in tags else 1 if "incomplete" in tags else 2
        if rank < best:
            selected=snap; best=rank
if selected:
    print(("promoted", "incomplete", "unverified")[best], selected["id"], selected.get("short_id") or selected["id"][:8])
else:
    print("missing")
PYPROMOTE
}
promoted=0; promotion_failure="snapshot missing"; current_id="$SNAPSHOT"
if [[ -n "$SNAPSHOT" ]]; then
  for attempt in 1 2; do
    promoted_id=""; state=unknown
    if [[ $attempt != 1 ]] && resolved=$(resolve_promotion); then
      read -r state resolved_id promoted_id <<<"$resolved"
      [[ -z "$resolved_id" ]] || current_id="$resolved_id"
    fi
    : > "$tag_out"
    if [[ $state == promoted ]]; then
      promoted=1
    elif [[ $state != missing && $state != unverified ]]; then
      tag_rc=0
      R tag --retry-lock "$PROMOTE_LOCK_WAIT" --remove incomplete --add "$MODE" "$current_id" >"$tag_out" 2>&1 || tag_rc=$?
      cat "$tag_out" >>"$LOG"
      if [[ $tag_rc == 0 ]]; then
        promotion_failure="snapshot could not be verified as promoted (restic tag reported success but the snapshot is still tagged incomplete or missing)"
        if resolved=$(resolve_promotion); then
          read -r state resolved_id promoted_id <<<"$resolved"
          [[ -z "$resolved_id" ]] || current_id="$resolved_id"
          [[ $state != promoted ]] || promoted=1
        fi
      elif restic_lock_error "$tag_out"; then promotion_failure="repository is locked"
      else promotion_failure="restic tag failed rc=$tag_rc"; fi
    else promotion_failure="snapshot could not be verified as promoted (snapshot incomplete, missing or without $MODE tag)"; fi
    if [[ $promoted == 1 ]]; then
      if [[ -n "$promoted_id" ]]; then SNAPSHOT="$promoted_id"
      else log "backup ($MODE): promoted snapshot ID lookup failed; result retains pre-tag ID $SNAPSHOT"; fi
      break
    fi
    log "backup ($MODE): snapshot promotion attempt $attempt failed: $promotion_failure"
    if [[ $attempt == 1 && $GB_UNLOCK_DONE == 0 ]]; then
      GB_UNLOCK_DONE=1
      unlock_rc=0
      R unlock >>"$LOG" 2>&1 || unlock_rc=$?
      log "backup ($MODE): plain restic unlock ran rc=$unlock_rc"
      alert "backup ($MODE): promotion was blocked/failed; plain restic unlock (stale locks only) was run before retrying (rc=$unlock_rc)"
    fi
  done
fi
rm -f "$promote_list" "$promote_err" "$tag_out"
if [[ $promoted != 1 ]]; then
  RESULT=incomplete; date +%s > "$GB_STATE/last-partial"
  alert "backup ($MODE): could not promote snapshot to complete; retention skipped; $promotion_failure"; exit 6
fi
RESULT=complete
if [[ $rc == 3 ]]; then
  log "backup ($MODE) complete with warnings: persistently unreadable regular files omitted (up to 20): ${summary[6]}"
fi
date +%s > "$GB_STATE/last-success-$MODE"
if [[ $MODE == auto ]]; then
  cp "$cur" "$GB_STATE/manifest-last-good.json"; date +%s > "$GB_STATE/last-success"
  # backup.lock serializes writers; readers see only the complete, bounded history.
  { [[ ! -f "$GB_STATE/hourly-history" ]] || cat "$GB_STATE/hourly-history"; cat "$GB_STATE/last-success"; } | tail -n 400 > "$GB_STATE/hourly-history.tmp"
  mv "$GB_STATE/hourly-history.tmp" "$GB_STATE/hourly-history"
  rm -f "$GUARD_LATCH" "$GB_STATE/last-partial" "$GB_STATE/backup-skipped"   # only a good hourly backup clears the latch
  [[ -z "$NO_FORGET_WHY" ]] && rm -f "$SQLITE_LATCH"   # ...and the SQLite latch needs a fully clean hourly
fi
log "backup ok mode=$MODE rc=$rc"
if [[ -n "$NO_FORGET_WHY" ]]; then log "forget skipped: $NO_FORGET_WHY"
elif [[ -e "$GUARD_LATCH" ]]; then alert "forget skipped: stale guard latch ($GUARD_LATCH) is set"
elif [[ -e "$SQLITE_LATCH" ]]; then alert "forget skipped: SQLite staging failed earlier ($SQLITE_LATCH is set; clears after a fully successful hourly backup)"
elif [[ -e "$GB_STATE/CHECK_FAILED" ]]; then log "forget skipped: integrity check failure latch is set"
elif [[ $FORGET == 1 && $MODE == auto ]]; then   # forget only; the actual prune happens daily in check.sh
  if prepare_retention; then
    restic_retry_unlock RT forget --host "$BACKUP_HOST" --tag auto "${KEEP[@]}" >>"$LOG" 2>&1 || alert "forget (auto) failed"
    restic_retry_unlock RT forget --host "$BACKUP_HOST" --tag quick "${KEEP_QUICK[@]}" >>"$LOG" 2>&1 || alert "forget (quick) failed"
    restic_retry_unlock RT forget --host "$BACKUP_HOST" --tag incomplete --keep-within 7d >>"$LOG" 2>&1 || alert "forget (incomplete) failed"
  else alert "forget skipped: incomplete snapshot tags could not be repaired"; fi
fi
exit 0
