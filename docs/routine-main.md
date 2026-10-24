# GrokBox-Main daily routine (backup health + server export)

GrokBox-Main owns this routine and creates it itself with `UpdateRoutine`. One run does two jobs:
1. **Box side:** keeps the scheduler alive after a box move, reads `status.sh`, and surfaces alerts.
2. **Server side:** exports every bot's conversation history (GrokBox-Assist included, but not Main
   itself) and Main's own + the owner's shared memory into `staging/server-export/`. The hourly snapshot
   picks it up.

It reports only problems. Its partner routine is [routine-assist.md](routine-assist.md). Why two bots and
why a bot routine at all: [bots.md](bots.md).

## Placeholders
| placeholder | meaning | example |
|---|---|---|
| `<REPO>` | path of this repo on the box | `/workspace/grokbox` |
| `<AGENTS_DIR>` | where the bots live on the box | `/home/box/agent-data/agents` |
| `<DRIVE_ACCOUNT>` | Google account that owns the backup Drive | `you@example.com` |
| `<REMOTE>` | `GB_REMOTE:GB_FOLDER` from config.env | `gdrive:GrokBox/restic` |
| `<LANGUAGE>` | language for reports | `English` |
| `<MAIN_ID>` / `<ASSIST_ID>` / `<PRIMARY_ID>` | agent ids of GrokBox-Main, GrokBox-Assist, the primary bot | |
| `<HOUR>` | run time in the owner's time zone; keep it away from `check.sh` (04:40) | `05:15` |

## Routine settings
- **Name:** `GrokBox-Main daily: backup health + server export`
- **Schedule:** daily at `<HOUR>`. GrokBox-Assist runs a few hours later.
- **Report:** only on problems, in `<LANGUAGE>`.

## Prompt
```text
GrokBox-Main daily run. Box backups go to <REMOTE> (Google Drive of <DRIVE_ACCOUNT>), repo at <REPO>.
Report to the owner ONLY if something below needs attention, in <LANGUAGE>; otherwise stay silent.
Rules: never print secrets (secrets/*, restic password, tokens, auth URLs); never use backup.sh --force;
never prune/forget/delete snapshots or Drive data; never print or summarize conversation content;
always call ReadTranscript and RecallMemory with write_to_file: true; delete only result files you created;
never read the server any other way (no cookies, scraped tokens or internal APIs);
do not change other bots' settings, routines or memory.

PART A - box backup health
A1. Run: cd <REPO> && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"
    Always run status.sh --local, even if install.sh --schedule failed.
A2. Healthy = schedule_rc=0 AND the last status line is "Overall: OK". If healthy, go to PART B.
A3. Otherwise run ./status.sh (full) and collect the "!!" lines.
    - "rclone config missing", "Drive unreachable", invalid_grant / token expired / 401 errors: the Drive
      authorisation is gone. Tell the owner it needs a new consent: run ./auth-gdrive.sh, open the printed
      localhost URL in the box's own browser, and the owner signs in as <DRIVE_ACCOUNT> and clicks Allow.
      Do not try to fix tokens yourself.
    - "stale-computer guard" (exit 4): do NOT force. Tell the owner; compare with ./restore.sh ls latest.
    - Any other alert: one line each, with the likely cause.
    Only run ./status.sh --ack after the cause is fixed AND the owner has been told.

PART B - server-side export of all bots (staging/server-export)
B1. For every directory name <id> in <AGENTS_DIR> (skip files such as *.json), EXCEPT <MAIN_ID> (yourself;
    GrokBox-Assist exports you), call ReadTranscript {in: <id>, limit: 200} (newest page). Run them in parallel.
B2. Run: python3 <REPO>/server-export-merge.py ingest --remove <all result files>
    Ingest a result that says "No conversation ... has the id" on its own, with --id <id>.
    It prints JSON {id: before}; {} means everything is complete.
B3. For each "id": N call ReadTranscript {in: id, limit: 200, before: N}; for "id": "newest" call it without
    before. Ingest again (B2). Repeat until it prints {}. For a long backlog you may also request
    before = N-35, N-70, ... in parallel (overlaps are de-duplicated, gaps reappear). Stop after 30 rounds
    and report if not done.
B4. Memory: call RecallMemory with about 10 generic queries ("user preferences", "projects", "bots and agents",
    "routines", "accounts and services", "decisions", "people", "this week", the current month name), then:
    python3 <REPO>/server-export-merge.py memory --remove --out grokbox-main-and-shared --label GrokBox-Main <files>
B5. Partner check: python3 <REPO>/server-export-merge.py age --max-hours 30 <MAIN_ID>
    Exit 1 means GrokBox-Assist has not exported you in 30 h: report "GrokBox-Assist did
    not run" (once the setup is older than a day).
B6. Read <REPO>/staging/server-export/INDEX.md. Report rows with status "gap" or warnings. Do not report
    "empty" / "not readable" rows, except a bot that was readable before and now is not.

Report format, only when something needs attention: one short list, Part A first (each with the exact
next step for the owner), then Part B. No logs, no message content, no secrets.
```

## First run
Right after creating the routine, run its steps once. The first export pages back through every
conversation, so it needs many rounds of B3. After that, each daily run only fetches what is new.
