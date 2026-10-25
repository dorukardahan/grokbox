# Health check, weekly test restore, alert hook, expected bots, Drive report

Five small features that make a running Grok Box easier to watch. All settings live in `config.env`
(defaults in `config.env.example`; older `config.env` files keep working, `lib.sh` fills in the defaults).

## 1. `doctor.sh`: one screen, plain language
```bash
./doctor.sh              # local checks only, no network
./doctor.sh --online     # plus one bounded Drive call (rclone about) to prove the token still works
./doctor.sh --json       # the same as one JSON object {overall, exit, checks: [{name, status, detail}]}
./status.sh --doctor     # identical (status.sh hands over to doctor.sh)
```
One line per topic, each `OK`, `WARN` or `PROBLEM` with what it means and the next step:
open alerts, pause flag and latches, scheduler + heartbeat, backup lock (free, or held by which job for how
long), last complete backup, last check (and the `CHECK_FAILED` latch), Drive auth (token present in
`rclone.conf`; `--online` tests it), quota/disk (`state/quota.status`), last test restore, Drive report
upload, expected bots. Ends with `Overall: OK | WARN | PROBLEM`.

Exit code: `0` all OK, `1` at least one WARN and no PROBLEM, `2` at least one PROBLEM. Rule of thumb:
PROBLEM = a human must act now (scheduler dead or hung, no complete backup for `ALERT_NO_SUCCESS_HOURS`,
failed check or test restore, missing credentials, 90 %+ full, open alerts); WARN = degraded but
self-healing or informational (incomplete last run, failed report upload, 80 %+ full, overdue test
restore, missing expected bot, paused).

It reads the shared state files (`last-backup.result`, `last-check.result`, `quota.status`,
`test-restore.result`, `report-upload.status`) defensively: a missing or garbled file shows as
"unknown" and never crashes the check. `status.sh --local` remains the detailed view the bot routines read.

## 2. Weekly test restore (`test-restore.sh --weekly`)
`scheduler.sh` runs a real test restore once a week, on `TEST_RESTORE_WEEKDAY` (0 = Sunday ... 6, default 0;
set `""` to turn the weekly run off) at `TEST_RESTORE_AT` (default `02:20`, keep it away from
`DAILY_CHECK_AT`). Slots are due-based: a slot missed while the box was off is caught up at the next tick.
The once-after-the-first-backup run and the monthly run from `check.sh` stay as they were.

What it does: takes `backup.lock` (waits 60 s when run by the scheduler, then retries next minute),
restores a sample from the latest hourly snapshot into a private `chmod 700` directory
`$RESTORE_BASE/restore-test-<date>/`, verifies every file against the snapshot metadata, and compares the
SHA-256 of each restored file with the live file when the live file is unchanged since the snapshot (same
size and mtime); files changed since the snapshot are skipped, not counted as errors. The sample always
contains the critical files that are in the snapshot: the config file, `TEST_RESTORE_PATHS`, the staged
brain export, the server-side export (`staging/server-export`) and the SQLite copies, plus
`TEST_RESTORE_RANDOM_FILES` random files (< 64 MB). The directory is removed on every exit path (trap).

Result: `state/test-restore.result` (`result=ok|failed`, `time`, `files`, `mismatches`, `snapshot`),
`state/test-restore-result.txt` (details), `state/last-test-restore` on success. Any mismatch or restore
error raises an alert (`TEST RESTORE FAILED (weekly): ...`) and the report/doctor show it.

## 3. Alert dedupe and the optional alert hook
**Dedupe (always on).** `alert()` records the same alert text (timestamp ignored) in `state/ALERT`,
`logs/alerts.log` and the hook **once per incident**. Repeats are only noted in the month log
(`ALERT (repeat N, same incident since ..., not re-recorded)`) and counted in `state/alert-seen`. A new
incident starts after `status.sh --ack` (which removes `state/alert-seen`) or `ALERT_DEDUPE_HOURS`
(default 24) after the first occurrence. Scripts should pass stable, specific messages so that one
ongoing problem is one incident.

**Hook (off by default).** `ALERT_HOOK` is a shell command run for every *new* alert with the alert text
on stdin and in `$GB_ALERT_MSG`, under `timeout` (`ALERT_HOOK_TIMEOUT`, default 60 s). Its output goes to
`logs/alert-hook.log`; a failing or hung hook is logged (`WARN alert hook exited rc=...`) and never fails
the job that raised the alert. A hook that itself raises an alert does not trigger the hook again.
The box cannot send mail on its own: the hook needs a mail command, a relay or a webhook you set up.
Examples (placeholders only; keep real addresses and URLs in your local `config.env`, never in the repo):
```bash
# e-mail through a local mail/sendmail setup (msmtp, ssmtp, a relay you configured)
ALERT_HOOK='mail -s "Grok Box alert on $(hostname)" you@example.com'
ALERT_HOOK='{ printf "Subject: Grok Box alert\n\n"; cat; } | sendmail you@example.com'
# chat webhook (Slack/Discord/Mattermost style: a JSON POST; python builds the JSON safely from stdin)
ALERT_HOOK='python3 -c "import json,sys,urllib.request as u; u.urlopen(u.Request(\"https://chat.example.com/hooks/<webhook-id>\", json.dumps({\"text\": sys.stdin.read()}).encode(), {\"Content-Type\": \"application/json\"}))"'
# ntfy-style push
ALERT_HOOK='curl -fsS -d @- https://ntfy.example.com/<topic>'
```
The bot routines still report every open alert in chat; the hook is an extra channel.

## 4. Expected-bot roster (`expected-bots.sh`)
`EXPECTED_BOTS=()` lists bots (names or agent ids) that must be in every server-side export. Keep the real
names in your local `config.env` only. The check reads `staging/server-export/state/positions.json`
(written by `server-export-merge.py`): a listed bot is missing when it was never exported, is recorded as
not readable, or its last export check is older than `EXPECTED_BOTS_MAX_HOURS` (default 26, so a skipped
daily routine is noticed). Names match case-insensitively and by slug (`GrokBox-Main` = `grokbox main`).
```bash
./expected-bots.sh            # one line; exit 0 = all present (or no roster), 1 = missing/stale, 2 = no export yet
./expected-bots.sh --alert    # same, and raise one (deduped) alert when bots are missing
```
`scheduler.sh` runs it with `--alert` after every hourly backup; `doctor.sh` shows the line (WARN when
bots are missing). "No export yet" is shown but never alerted: the bots' routines create the export.

## 5. Drive report (`report.sh`, `latest-backup-report.txt`)
After every hourly backup, daily check and test restore, `scheduler.sh` runs `report.sh`. It writes
`state/latest-backup-report.txt`, a short plain-text report in `$TZ`: last backup time and result
(complete / incomplete / failed / timeout), snapshot id, files, source size, added data, duration,
repository size (`restic stats`, if it answers within 5 min), last check + prune, last test restore, open
alert count. It contains no secrets, paths, ids or e-mail addresses (only `BACKUP_HOST`).

With `DRIVE_REPORT=1` (default) and an `rclone:` repository it is uploaded with `rclone copyto`
(replaces the file in place) into the **parent** of `GB_FOLDER`: `GrokBox/restic` ->
`GrokBox/latest-backup-report.txt`, so you can see the state of the backups in the Drive app without
opening anything. It never goes inside the restic folder; if `GB_FOLDER` has no parent folder the upload
is skipped with a log line. A failed upload never fails the backup: it is written to
`state/report-upload.status` (`result=failed`), shown as a `!!` line by `status.sh` and as WARN by
`doctor.sh`, and retried after the next hourly backup. `report.sh --no-upload` only writes the file;
`DRIVE_REPORT=0` turns the upload off.

## Files and state
| file | what |
|---|---|
| `doctor.sh`, `report.sh`, `expected-bots.sh` | the three new scripts |
| `state/alert-seen` | alert dedupe: `key first-seen count` per incident; removed by `status.sh --ack` |
| `logs/alert-hook.log` | output of `ALERT_HOOK` runs |
| `state/test-restore.result` | last test restore: `result`, `time`, `files`, `mismatches`, `snapshot` |
| `state/sched-test-restore` | date of the last weekly test-restore slot that ran |
| `state/latest-backup-report.txt`, `state/report-upload.status` | the Drive report and its last upload result |

Tests: `tests/fable.sh` (offline: local restic repository, a fake `rclone` for the Drive parts).
