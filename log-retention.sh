#!/usr/bin/env bash
# Optional log cleanup, called nightly by check.sh. Default: logs are kept FOREVER.
# Set LOG_RETENTION_DAYS=N in config.env to delete Grok Box's own monthly logs/backup-YYYY-MM.log
# files older than ~N days. alerts.log / alerts-acked.log are never touched, and nothing outside
# $GB_LOGS is ever deleted (find is rooted there, maxdepth 1, name-gated).
source "$(dirname "$0")/lib.sh"
if [[ ! "${LOG_RETENTION_DAYS:-0}" =~ ^[0-9]+$ ]]; then
  log "log retention: LOG_RETENTION_DAYS='${LOG_RETENTION_DAYS}' is not a number; keeping all logs"; exit 0; fi
(( LOG_RETENTION_DAYS > 0 )) || exit 0
mapfile -t old < <(find "$GB_LOGS" -maxdepth 1 -type f -name 'backup-*.log' -mtime "+$LOG_RETENTION_DAYS")
(( ${#old[@]} > 0 )) || exit 0
rm -f -- "${old[@]}"
log "log retention: deleted ${#old[@]} log file(s) older than ${LOG_RETENTION_DAYS}d (LOG_RETENTION_DAYS)"
