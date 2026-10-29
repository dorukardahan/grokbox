# GrokBox-Main daily routine (backup health + server export)

GrokBox-Main creates its daily routine with `UpdateRoutine`. The scheduled run checks health and
exports memory, then always hands transcript paging to its normal (parent) chat. Scheduled runs
have RecallMemory but no ReadTranscript and cannot talk to the owner. The parent chat reports only
problems. Partner: [routine-assist.md](routine-assist.md); setup: [bots.md](bots.md).

## Placeholders
| placeholder | meaning | example |
|---|---|---|
| `<REPO>` | path of this repo on the box | `/workspace/grokbox` |
| `<AGENTS_DIR>` | where the bots live on the box | `/home/box/agent-data/agents` |
| `<DRIVE_ACCOUNT>` | Google account that owns the backup Drive | `you@example.com` |
| `<REMOTE>` | `GB_REMOTE:GB_FOLDER` from config.env | `gdrive:GrokBox/restic` |
| `<LANGUAGE>` | language for reports | `English` |
| `<MAIN_ID>` / `<ASSIST_ID>` / `<PRIMARY_ID>` | agent ids of GrokBox-Main, GrokBox-Assist, the primary bot | |
| `<RESULT_DIR>` | directory for tool result files | `/workspace/agent-tools` |
| `<HOUR>` | run time in the owner's time zone; keep it away from `check.sh` (04:40) | `05:15` |

## Routine settings
- **Name:** `GrokBox-Main daily: backup health + server export`
- **Schedule:** daily at `<HOUR>`. GrokBox-Assist runs a few hours later.
- **Result:** always return the parent-chat handoff. Only the parent chat reports problems to the owner, in `<LANGUAGE>`.

## Step names
One numbering for both parts, so every step name is unique:
- **A1–A3** and **B4–B6** run in the scheduled prompt (health, memory, partner check, INDEX).
- **B1–B3** are the transcript export loop. They run only in the parent chat, followed by its
  **final check** (INDEX.md + `export-freshness.sh`). The handoff line names this loop as "(B1–B3)".

## Scheduled run
Store only this prompt in `UpdateRoutine`. Do not attempt B1–B3 here.
```text
GrokBox-Main daily run. Box backups go to <REMOTE> (Google Drive of <DRIVE_ACCOUNT>), repo at <REPO>.
Collect problems for the parent chat, in <LANGUAGE>. Always return the handoff below, even when healthy.
Rules: never print secrets (secrets/*, restic password, tokens, auth URLs); never use backup.sh --force;
never prune/forget/delete snapshots or Drive data; never print or summarize conversation content;
call RecallMemory with write_to_file: true when it offers it; delete only result files you created;
never read the server any other way (no cookies, scraped tokens or internal APIs);
do not change other bots' settings, routines or memory.

PART A - box backup health
A1. Run: cd <REPO> && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"; echo "--- open alerts:"; cat state/ALERT 2>/dev/null
    Always run status.sh --local, even if install.sh --schedule failed.
A2. Healthy = schedule_rc=0 AND the last status line is "Overall: OK" AND nothing is printed after
    "--- open alerts:". If healthy, go to B4. Include every open alert line in the handoff; the parent chat reports it to the owner.
A3. Otherwise run ./status.sh (full) and collect the "!!" lines.
    - "rclone config missing", "Drive unreachable", invalid_grant / token expired / 401 errors: the Drive
      authorisation is gone. Tell the parent chat to notify the owner it needs a new consent: run ./auth-gdrive.sh --reauth, open the printed
      localhost URL in the box's own browser, and the owner signs in as <DRIVE_ACCOUNT> and clicks Allow.
      Do not try to fix tokens yourself.
    - "stale-computer guard" (exit 4): do NOT force. Tell the parent chat to notify the owner; compare with ./restore.sh ls latest.
    - "backup.lock held for Nh" or "Scheduler loop has not ticked": a job is hung. Tell the parent chat to notify the owner; the
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
    Leave alerts visible for the parent chat. ./doctor.sh is a one-screen check.

PART B - memory, partner check and handoff (B1–B3 run in the parent chat)
B4. Memory (a sample, not a full dump): call RecallMemory with about 10 generic queries ("user preferences", "projects", "bots and agents",
    "routines", "accounts and services", "decisions", "people", "this week", the current month name), then:
    python3 <REPO>/server-export-merge.py memory --remove --out grokbox-main-and-shared --label GrokBox-Main <files>
    If RecallMemory has no write_to_file option (it then returns the result inline), paste each result
    VERBATIM into its own file with a quoted heredoc, one Shell call per result, e.g.
    cat > <RESULT_DIR>/grokbox-main-mem-1.txt <<'GROKBOX_MEM_END_7Q2'
    <the RecallMemory result, unchanged>
    GROKBOX_MEM_END_7Q2
    (numbered -1, -2, ...; the odd end marker cannot appear inside a result) and pass those files instead.
    Never edit, summarize or add facts.
B5. Partner check: python3 <REPO>/server-export-merge.py age --max-hours 26 <MAIN_ID>
    Exit 1 means GrokBox-Assist has not exported you in 26 h: include in the handoff "GrokBox-Assist did
    not export Main" (once the setup is older than a day).
B6. Read <REPO>/staging/server-export/INDEX.md. Report rows with status "gap" or warnings. Do not report
    "empty" / "not readable" rows, except a bot that was readable before and now is not.

ALWAYS end with a result to the parent chat whose first line is exactly:
EXPORT NOT DONE IN SCHEDULED RUN — parent: run the export loop (B1–B3) now
Then one line per health problem found (or "health: OK"), followed by any memory/partner/INDEX problems.
No logs, no message content, no secrets. This handoff is required on every run, healthy or not.
```

## Parent chat: export loop
On every handoff (or at any time), the normal chat runs the loop below. Keep the same safety rules
as the scheduled prompt, use `write_to_file: true`, and report to the owner only on problems,
including all problems in the handoff. Acknowledge alerts only after fixing the cause and telling
the owner. Paging may go to a subagent only if it has ReadTranscript: an automation/scheduled
subagent does not; a normal executor subagent started from the chat does.

```text
B1. For every directory name <id> in <AGENTS_DIR> (skip files such as *.json), EXCEPT <MAIN_ID> (yourself;
    GrokBox-Assist exports you) and ids in the deleted-bot list (DELETED_BOTS_FILE, default
    /home/box/agent-data/deleted-agents.json),
    call ReadTranscript {in: <id>, limit: 200} (newest page). Run them in parallel.
B2. Run: rc=0; python3 <REPO>/server-export-merge.py ingest --remove <the result files of this round> || rc=$?; echo "ingest_rc=$rc"
    Ingest a result that says "No conversation ... has the id" on its own, with --id <id>.
    ALWAYS judge the run by the printed ingest_rc line, never by the printed JSON. ingest_rc=0: the
    JSON {id: before} says what to fetch next; {} means everything is complete. ingest_rc=3: at least
    one page was rejected (the ERROR lines name the file; it is kept, not ingested). Refetch each
    rejected id with a SMALLER page (limit: 100, then limit: 50): before=<value> if the JSON lists
    one for that id, otherwise its newest page (a rejected newest page leaves {} in the output).
    Once the refetch reports ingest_rc=0, delete the rejected result file it replaces (a kept
    rejected file makes every later ingest exit 3 again). A page rejected twice: skip that id
    today, delete both result files, and report "<id>: transcript page rejected twice" to the
    owner. Nothing is lost: tomorrow's run fetches every newest page again.
B3. For each "id": N call ReadTranscript {in: id, limit: 200, before: N}; for "id": "newest" call it without
    before. Ingest only those new result files (B2). Repeat until ingest_rc=0 and the JSON prints {}.
    For a long backlog you may also request
    before = N-35, N-70, ... in parallel (overlaps are de-duplicated, gaps reappear). Stop after 30 rounds
    and report if not done.
Final check (after B3): read <REPO>/staging/server-export/INDEX.md. Report rows with status "gap" or
    warnings. Do not report "empty" / "not readable" rows, except a bot that was readable before and now is not.
Then run: cd <REPO> && ./export-freshness.sh
It must print "daily export OK"; otherwise report the problem to the owner.
```

## First run
After creating the scheduled routine, run health and memory steps once, and run B1–B3 and the
final check in the chat right away. The first export may need many paging rounds; later exports fetch what is new.
