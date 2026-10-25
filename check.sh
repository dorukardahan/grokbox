#!/usr/bin/env bash
# Daily: forget per retention policy (hourly `auto` chain + `quick` chain separately), prune, verify
# repo structure + a random subset of data. Monthly (day 1) or --test-restore: real test restore.
source "$(dirname "$0")/lib.sh"; need_creds
"$GB_DIR/log-retention.sh" || true   # optional LOG_RETENTION_DAYS cleanup (default: logs kept forever)
"$GB_DIR/quota-check.sh"   || true   # disk + Drive usage -> state/quota.status, alert at QUOTA_ALERT_PCT
exec 9>"$GB_STATE/backup.lock"
flock -w "${LOCK_WAIT:-3600}" 9 || { log "check: backup lock busy; not run now (scheduler retries)"; exit 75; }
took_lock check
log "check start"
R unlock >>"$LOG" 2>&1 || log "WARN restic unlock failed"   # removes only stale locks (e.g. left by a killed run)
if [[ -e "$GUARD_LATCH" ]]; then
  alert "check: forget/prune SKIPPED, stale guard latch ($GUARD_LATCH) is set; it clears after a successful hourly backup"
elif [[ -e "$SQLITE_LATCH" ]]; then
  alert "check: forget/prune SKIPPED, SQLite staging failed earlier ($SQLITE_LATCH is set; it clears after a fully successful hourly backup)"
else
  RT forget --host "$BACKUP_HOST" --tag auto "${KEEP[@]}" >>"$LOG" 2>&1 || alert "forget (auto) failed"
  RT forget --host "$BACKUP_HOST" --tag quick "${KEEP_QUICK[@]}" >>"$LOG" 2>&1 || alert "forget (quick) failed"
  R_TIMEOUT="$RESTIC_TIMEOUT_CHECK" RT prune >>"$LOG" 2>&1 || alert "prune failed or timed out (see $LOG)"
fi
if R_TIMEOUT="$RESTIC_TIMEOUT_CHECK" R check --read-data-subset "$CHECK_SUBSET" >>"$LOG" 2>&1; then log "check ok"; date +%s > "$GB_STATE/last-check"
else alert "restic check FAILED (see $LOG)"; exit 5; fi
if [[ "$(date +%d)" == 01 || "${1:-}" == --test-restore ]]; then
  GB_LOCK_HELD=1 "$GB_DIR/test-restore.sh" || true   # alerts on its own
fi
