#!/usr/bin/env bash
# Prints: ALERTS first (loud), then last hourly/quick snapshot times, running backup, last check /
# test restore, scheduler, snapshot counts and repo size. Ends with `Overall: OK | ATTENTION NEEDED`.
#   status.sh          full status (talks to the repository)
#   status.sh --local  no network (fast; for watchdogs)
#   status.sh --ack    acknowledge alerts: moves state/ALERT to logs/alerts-acked.log (and starts a new alert
#                      incident: the same alert text is recorded again if it recurs)
#   status.sh --doctor [--online] [--json]   one-screen plain-language health check (runs doctor.sh)
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
[[ "${1:-}" == --doctor ]] && exec "$GB_DIR/doctor.sh" "${@:2}"
R_TIMEOUT=300   # status must answer quickly even if Drive hangs
ts(){ [[ -s "$1" ]] && date -d "@$(cat "$1")" '+%F %H:%M %Z' || echo never; }
if [[ "${1:-}" == --ack ]]; then alert_ack; exit 0; fi   # under state/alert.lock; also starts a new dedupe incident
problems=0
if [[ -z "$(alert_channels)" && "$ALERT_CHANNEL_REQUIRED" != 0 && -z "$(chat_alert_check_fresh)" ]]; then
  problems=1
  echo "!! NO ALERT CHANNEL configured: nobody is told about failures (see docs/health-and-alerts.md, ./test-alert.sh)"
fi
if [[ -s "$GB_STATE/ALERT" ]]; then
  problems=1
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! BACKUP ALERT ($(wc -l < "$GB_STATE/ALERT") unacknowledged; newest last) - status.sh --ack once handled"
  tail -8 "$GB_STATE/ALERT" | sed 's/^/!! /'
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
if [[ -e "$GUARD_LATCH" ]]; then
  problems=1; echo "!! STALE GUARD LATCH set ($(cut -d' ' -f2- "$GUARD_LATCH" | cut -c1-150)): forget/prune are blocked until a successful hourly backup (see REBUILD.md)"; fi
if [[ -s "$GB_STATE/last-partial" ]] && (( $(cat "$GB_STATE/last-partial") >= $(cat "$GB_STATE/last-success" 2>/dev/null || echo 0) )); then
  problems=1; echo "!! last backup was INCOMPLETE (unreadable files) at $(ts "$GB_STATE/last-partial"); see logs"; fi
[[ -f "$GB_STATE/PAUSE" ]] && { problems=1; echo "!! PAUSED: state/PAUSE exists, the scheduler starts no backups (rm it to resume)"; }
echo "Profile: $BACKUP_PROFILE   secrets backed up: $BACKUP_SECRETS (restic-pass never)   venvs: $([[ $EXCLUDE_VENVS == 1 ]] && echo no || echo yes)   cache dirs: $([[ $EXCLUDE_CACHEDIRS == 1 ]] && echo no || echo yes)"
echo "Repo: $RESTIC_REPOSITORY"
echo "Last hourly snapshot:   $(ts "$GB_STATE/last-success")"
echo "Last quick snapshot:    $(ts "$GB_STATE/last-success-quick")   (every ${QUICK_EVERY_MIN} min)"
echo "Last check:             $(ts "$GB_STATE/last-check")"
echo "Last test restore OK:   $(ts "$GB_STATE/last-test-restore")$( [[ -s $GB_STATE/test-restore-result.txt ]] && echo "   result: $(sed -n 2p "$GB_STATE/test-restore-result.txt")")"
quick_limit=$(quick_max_age_s)
for k in last-success:hourly:$(( ALERT_NO_SUCCESS_HOURS * 3600 )) last-success-quick:quick:$quick_limit; do
  f=${k%%:*}; r=${k#*:}; lbl=${r%%:*}; lim=${r#*:}
  [[ "$f" == last-success-quick && "$QUICK_EVERY_MIN" == 0 ]] && continue
  [[ -s "$GB_STATE/$f" ]] || continue
  stamp=$(epoch_file "$GB_STATE/$f"); [[ -n "$stamp" ]] || continue
  age_s=$(( $(date +%s) - stamp ))
  (( age_s >= lim )) && { problems=1; echo "!! WARNING: last successful $lbl run is $(( age_s / 3600 ))h old"; }
done
if skipped_backup; then
  problems=1; echo "!! hourly backup skipped at $(date -d "@$SKIP_TIME" '+%F %H:%M %Z') (held by $SKIP_HOLDER); the next hourly will retry"
fi
prune_skip=$(kv_get "$GB_STATE/last-check.result" prune_skip)
if [[ "$prune_skip" =~ ^(latch|last-backup-not-complete|check-failed)$ ]]; then
  problems=1; echo "!! check: prune skipped ($prune_skip); repository keeps growing until a complete hourly backup"
fi
now=$(date +%s); first=$(cat "$GB_STATE/first-start" 2>/dev/null || echo "")
if [[ ! -s "$GB_STATE/last-success" ]]; then
  if [[ -n "$first" ]] && (( now - first >= ${FIRST_SUCCESS_GRACE_HOURS:-2} * 3600 )); then
    problems=1; echo "!! no successful hourly backup yet, $(( (now - first) / 3600 ))h after install/scheduler start"; fi
else   # a first success exists: the daily check must keep running (reference: last check, else first start)
  ref=$(cat "$GB_STATE/last-check" 2>/dev/null || echo "$first")
  if [[ -n "$ref" ]] && (( now - ref >= 48 * 3600 )); then
    problems=1; echo "!! last check is $(( (now - ref) / 3600 ))h old or never ran (expected daily)"; fi
fi
if lock_busy; then
  bp=$(pgrep -f "$GB_BIN/restic .* (backup|restore|prune|check|forget|tag|snapshots|stats)" | head -1)
  if [[ -n "$bp" ]]; then echo "Running now: restic pid $bp for $(ps -o etime= -p "$bp" | tr -d ' ')"
  else echo "Running now: lock held (preparing)"; fi
  problem=$(lock_problem)
  if [[ -n "$problem" ]]; then problems=1; echo "!! $problem"; fi
fi
if sched_running; then
  echo "Scheduler: running (pid $(sched_pid))"
  hb=$(cat "$GB_STATE/scheduler.heartbeat" 2>/dev/null || echo "")
  if [[ "$hb" =~ ^[0-9]+$ ]] && ! heartbeat_job_active "$hb" && (( $(date +%s) - hb >= ${HEARTBEAT_MAX_MIN:-90} * 60 )); then
    problems=1; echo "!! Scheduler loop has not ticked for $(( ($(date +%s) - hb) / 60 )) min (hung?): ./install.sh --restart-scheduler"; fi
else problems=1; echo "!! Scheduler: NOT running (run install.sh --schedule)"; fi
if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then problems=1; echo "!! credentials: restic password file missing ($RESTIC_PASSWORD_FILE); see AGENTS.md step 3"; fi
if is_rclone_repo && [[ ! -s "$RCLONE_CONFIG" ]]; then problems=1; echo "!! credentials: rclone config missing ($RCLONE_CONFIG); run auth-gdrive.sh"; fi
if [[ "$(kv_get "$GB_STATE/report-upload.status" result)" == failed ]]; then
  problems=1; echo "!! Drive report: $([[ "$(kv_get "$GB_STATE/report-upload.status" stage)" == build ]] && echo build || echo upload) of latest-backup-report.txt FAILED at $(date -d "@$(kv_epoch "$GB_STATE/report-upload.status" time)" '+%F %H:%M %Z' 2>/dev/null || echo ?) (see $LOG; retried after the next hourly backup)"; fi
if [[ -e "$GB_STATE/CHECK_FAILED" ]]; then problems=1; echo "!! CHECK FAILED latch set: prune blocked until a passing integrity check"; fi
if [[ -e "$SQLITE_LATCH" ]]; then problems=1; echo "!! SQLITE LATCH set ($(ts "$SQLITE_LATCH")): SQLite staging failed; forget/prune blocked until a fully successful hourly backup"; fi
if [[ -s "$GB_STATE/last-success" ]]; then   # same test-restore age and first-start grace as doctor.sh
  if [[ -s "$GB_STATE/last-test-restore" ]]; then
    tr_age=$(( (now - $(cat "$GB_STATE/last-test-restore")) / 86400 ))
    (( tr_age > TEST_RESTORE_MAX_DAYS )) && { problems=1; echo "!! last successful test restore is ${tr_age} days old (expected $([[ "$TEST_RESTORE_WEEKDAY" =~ ^[0-6]$ ]] && echo weekly || echo monthly))"; }
  elif [[ -n "$first" ]] && (( now - first > TEST_RESTORE_FIRST_DAYS * 86400 )); then
    problems=1; echo "!! no successful test restore yet, $(( (now - first) / 86400 )) days after install (run check.sh --test-restore)"; fi
fi
if [[ "${1:-}" == --local ]]; then echo "Overall: $([[ $problems == 0 ]] && echo OK || echo ATTENTION NEEDED)"; exit 0; fi
if [[ -s "$RESTIC_PASSWORD_FILE" ]] && { ! is_rclone_repo || [[ -s "$RCLONE_CONFIG" ]]; }; then
  if snap_out=$(R snapshots --no-lock --host "$BACKUP_HOST" --json 2>/dev/null | python3 -c '
import json,sys
s=sorted(json.load(sys.stdin),key=lambda x:x["time"])
if not s: print("Snapshots: 0 (first backup not finished yet)"); sys.exit()
a=[x for x in s if "auto" in (x.get("tags") or [])]; q=[x for x in s if "quick" in (x.get("tags") or [])]
print(f"Snapshots: {len(s)} total, {len(a)} hourly/daily/weekly/monthly (auto), {len(q)} quick")
last=s[-1]
print(f"""Latest: {last["short_id"]} {",".join(t for t in last.get("tags",[]) if "=" not in t)} at {last["time"][:19]} ({last["time"][-6:]})""")
sm=last.get("summary") or {}
if sm: print(f"""Latest snapshot: {sm.get("total_files_processed")} files, {sm.get("total_bytes_processed",0)/1e9:.2f} GB source, added {sm.get("data_added_packed",sm.get("data_added",0))/1e6:.0f} MB""")'); then
    echo "$snap_out"
    if [[ "$snap_out" == "Snapshots: 0"* ]]; then problems=1; echo "!! repository is empty (no snapshots yet)"; fi
  else problems=1; echo "!! could not list snapshots in the repository"; fi
  R stats --no-lock --mode raw-data --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(f"""Repo size: {d["total_size"]/1e9:.2f} GB""")' 2>/dev/null || true
else problems=1; echo "Not configured yet (missing restic password file or rclone.conf)."; fi
echo "Overall: $([[ $problems == 0 ]] && echo OK || echo ATTENTION NEEDED)"
