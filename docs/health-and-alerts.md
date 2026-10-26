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
`test-restore.result`, `report-upload.status`) defensively: every number must be a bounded plain integer
and every timestamp a plausible epoch (`lib.sh`: `num_ok`, `epoch_ok`, `kv_num`, `kv_epoch`); a missing,
garbled or out-of-range value shows as "unknown" and never crashes the check (no octal surprises from
`08`, no overflow). `status.sh --local` remains the detailed view the bot routines read.

Lock and heartbeat lines follow [docs/lock-and-prune-safety.md](lock-and-prune-safety.md): the recorded
holder counts as alive only when that pid really has `backup.lock` open (`/proc/<pid>/fd`), never because a
pid merely exists; an orphaned or garbled record is a PROBLEM that names the leftover holder processes. A
stale scheduler heartbeat is excused only while the scheduler's own verified child job holds the lock
(taken after the last tick, within the job budget); an unrelated or orphaned lock never hides a hung loop.

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
`state/test-restore-result.txt` (details), `state/last-test-restore` on success. Every failure, including
a `restic snapshots`/`ls` call that fails or times out and setup errors, raises an alert
(`TEST RESTORE FAILED (weekly): ...`), writes `result=failed` (an older `result=ok` never survives a failed
attempt) and exits 6; the report and doctor show it. A busy backup lock is not a failure: exit 75, the
result file is left alone and the scheduler retries next minute.

## 3. Alert dedupe and the optional alert hook
**Dedupe (always on).** `alert()` records the same alert in `state/ALERT`, `logs/alerts.log` and the hook
**once per incident**. The incident key ignores the timestamp and every number in the text, so a message
whose age, count or pid grows every hour (`backup.lock held for 13h ...`, `... 14h ...`, `no successful
HOURLY snapshot for 5h`) is one incident: the first text is recorded, every repeat is noted in full in the
month log (`ALERT (repeat N, same incident since ..., not re-recorded): <current text>`) and counted in
`state/alert-seen`. A message that differs in words (another job, another bot, another error) is a new
incident. A new incident also starts after `status.sh --ack` (which removes `state/alert-seen`) or
`ALERT_DEDUPE_HOURS` (default 24) after the first occurrence. The decision and the state writes happen
under `state/alert.lock` (concurrent jobs, `--ack`), which is released before the hook runs, so a hook
that raises an alert cannot deadlock. Scripts should still pass stable, specific messages.

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
(written by `server-export-merge.py`). A listed bot is **present** only when it is there, readable, checked
within `EXPECTED_BOTS_MAX_HOURS` (default 26, so a skipped daily routine is noticed) and its export is
**complete** by the merger's own rule (`max_pos >= total - 1` and no pending pages; an empty conversation,
`total` 0, is complete). A bot whose record was only touched (a recent `checked` with nothing exported, or
pages still pending) is never "present". While the parent chat is still paging, such a gap is reported as
*export in progress* for `EXPECTED_BOTS_GRACE_MIN` (default 60) minutes after the last check; after that it
counts as missing. Names match case-insensitively and by slug (`GrokBox-Main` = `grokbox main`).
```bash
./expected-bots.sh            # one line; exit 0 = all present or in progress (or no roster), 1 = missing/stale/incomplete, 2 = no export yet
./expected-bots.sh --alert    # same, and raise one (deduped) alert when bots are missing
```
`scheduler.sh` runs it with `--alert` after every hourly backup; `doctor.sh` shows the line (WARN when
bots are missing). The alert text is stable per incident (reasons, no ages), so a bot that stays missing
is one alert until `status.sh --ack`. "No export yet" is shown without an alert during the installation
grace: once the first start (`state/first-start`) is older than `EXPECTED_BOTS_MAX_HOURS` and there is
still no export at all, a nonempty roster raises one alert (the bots' parent chats create the transcript export).

Deleted bots may stay in `EXPECTED_BOTS`: ids in `DELETED_BOTS_FILE` (default
`/home/box/agent-data/deleted-agents.json`) and names or ids in `RETIRED_BOTS=()` are exempt from
missing/stale alerts. Retired names match case-insensitively or by slug. The status shows
names as “Helper Bot (deleted): history kept (N messages)”, or
“history kept (K of N messages, export incomplete)” for partial history. With a known total but
no exported messages it shows “nothing exported (0 of N messages)”; absent records, or empty or
unreadable records with nothing kept and no known positive total, show “never exported”. Previously
exported history that is no longer readable shows “history kept (K messages, no longer readable)”.
The suffix is added only once, including for `RETIRED_BOTS`.
An id roster entry differing from the display name adds its first eight characters in brackets,
for example “Helper Bot (deleted) [tid-2]: never exported”. History is never removed.
Set `DELETED_BOTS_FILE=""` to disable the list. Missing or invalid lists are silently ignored.
When only deleted/retired export records match, or none, `AGENTS_DIR` (default `/home/box/agent-data/agents`)
is checked for active replacements using directory ids and `profile.json` names. An unexported
replacement is missing (“never exported”); the deleted predecessor’s history remains in the suffix.
Missing/unreadable inventories and missing/invalid profiles are silently tolerated.
Only active bots count toward export checks; an entirely deleted roster is OK even before any export.

`export-freshness.sh` adds a separate **daily-export-missed** alert when no active per-bot check
is newer than `EXPORT_MISSED_HOURS` (default 26; 0 disables). It ignores deleted/retired and
unreadable bots. The scheduler runs it with `--alert` immediately after `expected-bots.sh`;
`doctor.sh` shows a "daily export" row. Missing/empty state gets the same first-start grace,
using this threshold; garbled state warns immediately. Alert text stays stable as ages grow.
Both alerts can fire: freshness checks that any export happened, while the roster checks each bot.
Scheduled routines cannot pull transcripts: run the parent chat loop in [routine-main.md](routine-main.md).

## 5. Drive report (`report.sh`, `latest-backup-report.txt`)
After every hourly backup, daily check and test restore, `scheduler.sh` runs `report.sh`. It writes
`state/latest-backup-report.txt`, a short plain-text report in `$TZ`: last backup time and result
(complete / incomplete / failed / timeout), files, source size, added data, duration, repository size
(`restic stats`, if it answers within 5 min), last check + prune, last test restore, open alert count. It
contains no secrets, paths, snapshot ids or e-mail addresses (only `BACKUP_HOST`). The numbers come from
`state/last-backup.result`; a valid `0` (a failed run) is shown as `0`, and the newest snapshot's summary
only fills in missing values when that snapshot belongs to the reported run (or on an older install
without `last-backup.result`). Garbled values are "unknown".

With `DRIVE_REPORT=1` (default) and an `rclone:` repository it is uploaded with `rclone copyto`
(replaces the file in place) into the **parent** of `GB_FOLDER`: `GrokBox/restic` ->
`GrokBox/latest-backup-report.txt`, so you can see the state of the backups in the Drive app without
opening anything. It never goes inside the restic folder; if `GB_FOLDER` has no parent folder the upload
is skipped with a log line. A failed upload, or a report that could not be built, never fails the backup:
it is written to `state/report-upload.status` (`result=failed`, `stage=upload|build`), shown as a `!!`
line by `status.sh` and as WARN by `doctor.sh`, and retried after the next hourly backup. Runs are
serialized by `state/report.lock` and use a private scratch directory, so two invocations can never mix
their inputs or upload a half-written file. `report.sh --no-upload` only writes the file; `DRIVE_REPORT=0`
turns the upload off.

## Files and state
| file | what |
|---|---|
| `doctor.sh`, `report.sh`, `expected-bots.sh`, `export-freshness.sh` | health checks and reporting |
| `state/alert-seen`, `state/alert.lock` | alert dedupe: `key first-seen count` per incident (removed by `status.sh --ack`); the lock around it |
| `state/report.lock` | serializes `report.sh` runs |
| `logs/alert-hook.log` | output of `ALERT_HOOK` runs |
| `state/test-restore.result` | last test restore: `result`, `time`, `files`, `mismatches`, `snapshot` |
| `state/sched-test-restore` | date of the last weekly test-restore slot that ran |
| `state/latest-backup-report.txt`, `state/report-upload.status` | the Drive report and its last upload result |

Tests: `tests/health.sh` (offline: local restic repository, a fake `rclone` for the Drive parts, a fake
`restic` front for failure injection).
