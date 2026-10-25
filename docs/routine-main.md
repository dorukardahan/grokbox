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
always call ReadTranscript (and RecallMemory, when it offers it) with write_to_file: true; delete only result files you created;
never read the server any other way (no cookies, scraped tokens or internal APIs);
do not change other bots' settings, routines or memory.

PART A - box backup health
A1. Run: cd <REPO> && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"; echo "--- open alerts:"; cat state/ALERT 2>/dev/null
    Always run status.sh --local, even if install.sh --schedule failed.
A2. Healthy = schedule_rc=0 AND the last status line is "Overall: OK" AND nothing is printed after
    "--- open alerts:". If healthy, go to PART B. Every open alert line is reported to the owner (this
    chat report is the alert channel: the box itself cannot send messages).
A3. Otherwise run ./status.sh (full) and collect the "!!" lines.
    - "rclone config missing", "Drive unreachable", invalid_grant / token expired / 401 errors: the Drive
      authorisation is gone. Tell the owner it needs a new consent: run ./auth-gdrive.sh --reauth, open the printed
      localhost URL in the box's own browser, and the owner signs in as <DRIVE_ACCOUNT> and clicks Allow.
      Do not try to fix tokens yourself.
    - "stale-computer guard" (exit 4): do NOT force. Tell the owner; compare with ./restore.sh ls latest.
    - "backup.lock held for Nh" or "Scheduler loop has not ticked": a job is hung. Tell the owner; the
      safe restart is ./install.sh --restart-scheduler (waits for the lock).
    Lock recovery: the timeout normally ends hung jobs automatically (TERM, then KILL after 60 seconds).
    Use ./install.sh --restart-scheduler --force only when the lock age exceeds
    RESTIC_TIMEOUT_BACKUP plus grace (for check jobs, allow the sequential check/prune timeout budget),
    or the scheduler heartbeat is stale by more than 2 hours. Inspect status.sh --local first.
    Force verifies the actual lock descriptors and terminates that job and its children, including escaped
    rclone process groups; it refuses a free or unverifiable lock. Never repeatedly force an active upload.
    Auth re-consent exit 75 means the lock is busy: retry in a few minutes.
    - To test the Drive login without changing anything: ./auth-gdrive.sh --test
    - Any other alert: one line each, with the likely cause.
    Only run ./status.sh --ack after the cause is fixed AND the owner has been told.

PART B - server-side export of all bots (staging/server-export)
B1. For every directory name <id> in <AGENTS_DIR> (skip files such as *.json), EXCEPT <MAIN_ID> (yourself;
    GrokBox-Assist exports you), call ReadTranscript {in: <id>, limit: 200} (newest page). Run them in parallel.
B2. Run: rc=0; python3 <REPO>/server-export-merge.py ingest --remove <all result files> || rc=$?
    Ingest a result that says "No conversation ... has the id" on its own, with --id <id>.
    ALWAYS judge the run by rc, never by the printed JSON. rc=0: the JSON {id: before} says what to
    fetch next; {} means everything is complete. rc=3: at least one page was rejected (the ERROR lines
    name the file; it is kept, not ingested). Refetch each rejected id with a SMALLER page
    (limit: 100, then limit: 50): before=<value> if the JSON lists one for that id, otherwise its
    newest page (a rejected newest page leaves {} in the output). A page rejected twice: skip that id
    today, delete the rejected result file, and report "<id>: transcript page rejected twice" to the
    owner. Nothing is lost: tomorrow's run fetches every newest page again.
B3. For each "id": N call ReadTranscript {in: id, limit: 200, before: N}; for "id": "newest" call it without
    before. Ingest again (B2). Repeat until B2 exits 0 and prints {}. For a long backlog you may also request
    before = N-35, N-70, ... in parallel (overlaps are de-duplicated, gaps reappear). Stop after 30 rounds
    and report if not done.
B4. Memory: call RecallMemory with about 10 generic queries ("user preferences", "projects", "bots and agents",
    "routines", "accounts and services", "decisions", "people", "this week", the current month name), then:
    python3 <REPO>/server-export-merge.py memory --remove --out grokbox-main-and-shared --label GrokBox-Main <files>
    If RecallMemory has no write_to_file option (it then returns the result inline), paste each result
    VERBATIM into its own file with a quoted heredoc, one Shell call per result, e.g.
    cat > /workspace/agent-tools/grokbox-main-mem-1.txt <<'GROKBOX_MEM_END_7Q2'
    <the RecallMemory result, unchanged>
    GROKBOX_MEM_END_7Q2
    (numbered -1, -2, ...; the odd end marker cannot appear inside a result) and pass those files instead.
    Never edit, summarize or add facts.
B5. Partner check: python3 <REPO>/server-export-merge.py age --max-hours 26 <MAIN_ID>
    Exit 1 means GrokBox-Assist has not exported you in 26 h: report "GrokBox-Assist did
    not run" (once the setup is older than a day).
B6. Read <REPO>/staging/server-export/INDEX.md. Report rows with status "gap" or warnings. Do not report
    "empty" / "not readable" rows, except a bot that was readable before and now is not.

Report format, only when something needs attention: one short list, Part A first (each with the exact
next step for the owner), then Part B. No logs, no message content, no secrets.
```

## First run
Right after creating the routine, run its steps once. The first export pages back through every
conversation, so it needs many rounds of B3. After that, each daily run only fetches what is new.
