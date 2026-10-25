#!/usr/bin/env bash
# Daily: forget per retention policy (hourly `auto` chain + `quick` chain separately), verify, prune
# repo structure + a random subset of data. Monthly (day 1) or --test-restore: real test restore.
source "$(dirname "$0")/lib.sh"; need_creds
"$GB_DIR/log-retention.sh" || true   # optional LOG_RETENTION_DAYS cleanup (default: logs kept forever)
"$GB_DIR/quota-check.sh"   || true   # disk + Drive usage -> state/quota.status, alert at QUOTA_ALERT_PCT
exec 9>"$GB_STATE/backup.lock"
flock -w "${LOCK_WAIT:-3600}" 9 || { log "check: backup lock busy; not run now (scheduler retries)"; exit 75; }
took_lock check
CHECK_RESULT=failed; PRUNED=0
write_check_result() {
  printf 'result=%s\ntime=%s\npruned=%s\n' "$CHECK_RESULT" "$(date +%s)" "$PRUNED" > "$GB_STATE/last-check.result.tmp"
  mv "$GB_STATE/last-check.result.tmp" "$GB_STATE/last-check.result"
}
trap write_check_result EXIT
log "check start"
R unlock >>"$LOG" 2>&1 || log "WARN restic unlock failed"   # removes only stale locks (e.g. left by a killed run)
if [[ -e "$GUARD_LATCH" ]]; then
  alert "check: forget/prune SKIPPED, stale guard latch ($GUARD_LATCH) is set; it clears after a successful hourly backup"
elif [[ -e "$SQLITE_LATCH" ]]; then
  alert "check: forget/prune SKIPPED, SQLite staging failed earlier ($SQLITE_LATCH is set; it clears after a fully successful hourly backup)"
elif [[ -e "$GB_STATE/CHECK_FAILED" ]]; then
  log "check: forget skipped; integrity check failure latch is set"
elif prepare_retention; then
  RT forget --host "$BACKUP_HOST" --tag auto "${KEEP[@]}" >>"$LOG" 2>&1 || alert "forget (auto) failed"
  RT forget --host "$BACKUP_HOST" --tag quick "${KEEP_QUICK[@]}" >>"$LOG" 2>&1 || alert "forget (quick) failed"
  RT forget --host "$BACKUP_HOST" --tag incomplete --keep-within 7d >>"$LOG" 2>&1 || alert "forget (incomplete) failed"
else
  alert "check: retention skipped; incomplete snapshot tags could not be repaired"
fi
# Never prune a repository until this run's integrity check passes.
if R_TIMEOUT="$RESTIC_TIMEOUT_CHECK" R check --read-data-subset "$CHECK_SUBSET" >>"$LOG" 2>&1; then
  CHECK_RESULT=ok; log "check ok"; date +%s > "$GB_STATE/last-check"; rm -f "$GB_STATE/CHECK_FAILED"
else
  date +%s > "$GB_STATE/CHECK_FAILED"
  alert "restic check FAILED; prune blocked until a passing check (see $LOG)"; exit 5
fi
last_result=$(backup_result_status)
if [[ -e "$GUARD_LATCH" || -e "$SQLITE_LATCH" || -e "$GB_STATE/CHECK_FAILED" ]]; then
  log "prune skipped: safety latch set"
elif [[ "$last_result" != complete ]]; then
  log "prune skipped: last hourly backup incomplete, interrupted, failed or unknown; uploaded packs retained until a complete backup"
else
  if R_TIMEOUT="$RESTIC_TIMEOUT_CHECK" RT prune >>"$LOG" 2>&1; then PRUNED=1
  else alert "prune failed or timed out (see $LOG)"; fi
fi
if [[ "$(date +%d)" == 01 || "${1:-}" == --test-restore ]]; then
  GB_LOCK_HELD=1 "$GB_DIR/test-restore.sh" || true   # alerts on its own
fi
