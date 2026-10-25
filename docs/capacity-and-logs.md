# Capacity watch and log retention

Two small nightly housekeeping jobs run at the start of `check.sh` (daily, default 04:40), before it
takes the backup lock, so they run even on nights when the lock is busy. Both are separate scripts
and never fail the check: `log-retention.sh` and `quota-check.sh`.

## Capacity watch (`quota-check.sh`)
Measures, cheaply and without uploading anything:
- **local disk**: `df` of every filesystem that holds `$GB_STATE`, `$GB_STAGING` or one of the
  `BACKUP_ROOTS`; the fullest one is reported;
- **Drive quota**: `rclone about <remote>: --json` (account-wide usage) — only for `rclone:`
  repositories, bounded by `RCLONE_TIMEOUT`. A failed or unparsable query is one log line, never
  fatal; the corresponding values are simply absent until the next night.

The result is written to `state/quota.status` (key=value lines; readers must treat missing or garbled
values as "unknown"):

```
time=<epoch>            when the sample was taken
disk_pct=<n>            fullest local filesystem, percent (integer)
disk_path=<mount>       that filesystem's mount point
drive_used=<bytes>      Drive quota used (rclone: repos only)
drive_total=<bytes>     Drive quota total (absent on unlimited plans)
drive_pct=<n>           percent of the Drive quota used (absent if total is unknown)
```

Alerts go through the normal `alert()` channel (`state/ALERT`, shown by `status.sh`, reported by the
bot routines) when local disk or Drive usage reaches `QUOTA_ALERT_PCT` (default 90). The Drive
message reminds you that pruned data sits in the Drive trash for ~30 days with `PRUNE_USE_TRASH=1`
(default) and still counts against the quota — emptying the trash frees it (see the
undo-prune-from-trash notes in `PRIVACY.md` / README).

To query by hand: `./quota-check.sh && cat state/quota.status`.

## Log retention (`log-retention.sh`)
By default Grok Box keeps its logs **forever** (monthly `logs/backup-YYYY-MM.log` files are small).
Set `LOG_RETENTION_DAYS=N` in `config.env` to delete monthly `logs/backup-*.log` files older than
~N days. `0` or unset keeps everything. `logs/alerts.log` and `logs/alerts-acked.log` are never
deleted (they are the alert history), nothing outside `$GB_LOGS` is ever touched, and the log file
currently being written can never match the age filter. Each cleanup is one line in the current log.
