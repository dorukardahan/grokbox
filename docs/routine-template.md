# Daily routine template: health check + server-side export

Grok Box needs **one** daily Grok Bot routine. It does two jobs in one run:

1. **Health.** Restart the scheduler after a box move, read `status.sh`, and surface alerts.
2. **Server-side export.** Pull every bot's conversation history and the bot's memory from the Grok Bot
   servers into `staging/server-export/`. The hourly snapshot then backs it up with everything else.

The routine stays silent when everything is fine and reports only problems.

## Why it has to be a bot routine
- `ReadTranscript` and `RecallMemory` are tools of the Grok Bot itself. They are not programs, and they
  have no CLI or public API that a script could call. `scheduler.sh`, cron and shell scripts cannot reach
  them. Only the bot can, while a routine runs.
- So the routine does the tool calls and saves every result to a file (`write_to_file: true`). Then
  `server-export-merge.py` (plain Python, no network) merges those files on disk.
- **Do not** try to read the server another way. That means no session cookies, no scraped tokens and
  no internal app APIs. It is unsafe, it breaks without warning, and it is not needed.
- A routine is part of the bot's own settings. Create it with the bot's routine tool (`UpdateRoutine`),
  not with a script.

## Placeholders
| placeholder | meaning | example |
|---|---|---|
| `<REPO>` | path of this repo on the box | `/workspace/grokbox` |
| `<DRIVE_ACCOUNT>` | Google account that owns the backup Drive | `you@example.com` |
| `<REMOTE>` | rclone remote + folder (`GB_REMOTE:GB_FOLDER` in config.env) | `gdrive:GrokBox/restic` |
| `<AGENTS_DIR>` | where the bots live on the box | `/home/box/agent-data/agents` |
| `<LANGUAGE>` | language for reports to the user | `English` |
| `<HOUR>` | when it runs, in the user's time zone | `03:30` |

## Routine settings
- **Name:** `Grok Box daily: backup health + server export`
- **Schedule:** daily at `<HOUR>` (user's time zone). Pick a time away from `check.sh` (default 04:40).
- **Report:** only on problems, in `<LANGUAGE>`. On a clean run, say nothing (or one line if the routine
  UI needs output).

## Prompt (paste into the routine, then replace the placeholders)

```text
Daily Grok Box run. Backups of this box go to <REMOTE> (Google Drive of <DRIVE_ACCOUNT>), repo at <REPO>.
Report to the user ONLY if something below needs attention, in <LANGUAGE>. Otherwise stay silent.
Rules: never print secrets (secrets/*, restic password, tokens, auth URLs); never use backup.sh --force;
never prune/forget/delete snapshots or Drive data; never print or summarize conversation content;
always call ReadTranscript and RecallMemory with write_to_file: true; delete only the result files you created.
Never read the server any other way (no cookies, scraped tokens or internal APIs).

PART A - backup health
A1. Run: cd <REPO> && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"
    Always run status.sh --local, even if install.sh --schedule failed.
A2. Healthy = schedule_rc=0 AND the last status line is "Overall: OK". If healthy, go to PART B.
A3. Otherwise run ./status.sh (full, with network) and collect the "!!" lines.
    - "rclone config missing", "Drive unreachable", invalid_grant / token expired / 401 errors:
      the Drive authorisation is gone. Tell the user that it needs a new consent: run ./auth-gdrive.sh,
      open the printed localhost URL in the box's own browser, and the user signs in as <DRIVE_ACCOUNT>
      and clicks Allow. Do not try to fix tokens yourself.
    - "stale-computer guard" (exit 4): do NOT force. Tell the user, and compare with ./restore.sh ls latest.
    - Any other alert: report it in one line each, with what you think caused it.
    Only run ./status.sh --ack after the cause is fixed AND the user has been told.

PART B - server-side export (staging/server-export, picked up by the next hourly snapshot)
B1. For every directory name <id> in <AGENTS_DIR> (skip files such as *.json), call
    ReadTranscript {in: <id>, limit: 200} with write_to_file: true (newest page). Run these in parallel.
B2. Run: python3 <REPO>/server-export-merge.py ingest --remove <all result files>
    Ingest a result that says "No conversation ... has the id" on its own, with --id <id>.
    The script prints JSON {id: before}. {} means everything is complete.
B3. For each "id": N call ReadTranscript {in: id, limit: 200, before: N} (write_to_file: true); for
    "id": "newest" call it without before. Ingest again (B2). Repeat until the script prints {}.
    For a long backlog you may also request before = N-35, N-70, ... in parallel: overlaps are
    de-duplicated and any gap shows up again in the output. Stop after 30 rounds and report if not done.
B4. Memory: call RecallMemory (write_to_file: true) with about 10 generic queries, e.g. "user preferences",
    "projects", "bots and agents", "routines", "accounts and services", "decisions", "people",
    "this week", the current month name. Then run:
    python3 <REPO>/server-export-merge.py memory --remove <result files>
B5. Read <REPO>/staging/server-export/INDEX.md. Report a row whose status is "gap" or has warnings.
    Do not report "empty" or "not readable" rows, except a bot that was readable before and now is not.

Report format, only when something needs attention: one short list with Part A problems first (each one
with the exact next step for the user), then Part B problems. No logs, no message content, no secrets.
```

## First run
Right after setup, run the routine once by hand, or ask the bot to "run the Grok Box daily routine now".
The first export pages back through every conversation, so it takes many rounds of B3. That is expected.
After that, each daily run only fetches what is new.

See also [server-export.md](server-export.md) (layout and merge logic) and [../AGENTS.md](../AGENTS.md) step 8.
