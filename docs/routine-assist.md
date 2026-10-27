# GrokBox-Assist daily routine (health + handoff, watches Main)

GrokBox-Assist creates its routine with `UpdateRoutine`, a few hours after Main. Scheduled runs
have RecallMemory but no ReadTranscript and cannot talk to the owner. They always hand transcript
paging to Assist's normal (parent) chat. That chat exports Main and the primary chat, covers stale
exports, and reports only problems. Background: [bots.md](bots.md).

## Placeholders
Same as [routine-main.md](routine-main.md): `<REPO>`, `<AGENTS_DIR>`, `<DRIVE_ACCOUNT>`, `<REMOTE>`,
`<LANGUAGE>`, `<MAIN_ID>`, `<ASSIST_ID>`, `<PRIMARY_ID>`, `<RESULT_DIR>`. In addition:
- `<MAIN_HOUR>`: when Main runs.
- `<HOUR>`: when this routine runs, e.g. `09:00` if Main runs at `05:15`.

## Routine settings
- **Name:** `GrokBox-Assist daily: health + handoff, watch Main`
- **Schedule:** daily at `<HOUR>` (owner's time zone), at least 2 hours after `<MAIN_HOUR>`.
- **Result:** always return the parent-chat handoff. Only the parent chat reports problems to the owner, in `<LANGUAGE>`.

## Scheduled run
Store only this prompt in `UpdateRoutine`. Do not attempt transcript paging here.

```text
GrokBox-Assist daily run. Repo at <REPO>. Collect problems for the parent chat, in <LANGUAGE>.
Rules: never print secrets; never use backup.sh --force; never prune/forget/delete snapshots or Drive data;
never print or summarize conversation content; use write_to_file: true for RecallMemory when offered;
delete only result files you created; no cookies, scraped tokens or internal APIs;
do not change other bots' settings, routines or memory.

1. Memory: RecallMemory with 3-5 generic queries ("user preferences", "projects", "decisions", "this week"),
   then: python3 <REPO>/server-export-merge.py memory --remove --out grokbox-assist-and-shared --label GrokBox-Assist <files>
   If RecallMemory has no write_to_file option (it then returns the result inline), paste each result
   VERBATIM into its own file with a quoted heredoc, one Shell call per result, e.g.
   cat > <RESULT_DIR>/grokbox-assist-mem-1.txt <<'GROKBOX_MEM_END_7Q2'
   <the RecallMemory result, unchanged>
   GROKBOX_MEM_END_7Q2
   (numbered -1, -2, ...; the odd end marker cannot appear inside a result) and pass those files instead.
   Never edit, summarize or add facts.
2. Scheduler self-heal + health, EVERY run (not only when Main missed its run):
   cd <REPO> && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"; echo "--- open alerts:"; cat state/ALERT 2>/dev/null
   (install.sh --schedule is a no-op when the scheduler runs; after a box move it starts it again.)
    Lock recovery: the timeout normally ends hung jobs automatically (TERM, then KILL after 60 seconds).
    Use ./install.sh --restart-scheduler --force only when the lock age exceeds
    RESTIC_TIMEOUT_BACKUP plus grace (for check jobs, allow the sequential check/prune timeout budget),
    or the scheduler heartbeat is stale by more than 2 hours. Inspect status.sh --local first.
    Force verifies the actual lock descriptors and terminates that job and its children, including escaped
    rclone process groups; it refuses a free or unverifiable lock. Never repeatedly force an active upload.
    Auth re-consent exit 75 means the lock is busy: retry in a few minutes.
   Age checks (read-only): python3 <REPO>/server-export-merge.py age --max-hours 26 <ASSIST_ID>
   Main normally exports Assist, so exit 1 means Main's daily export did not happen today.
   Also check every non-deleted id in AGENTS_DIR except <ASSIST_ID> with age --max-hours 26;
   include stale ids in the handoff for the parent chat's fallback loop.
   - schedule_rc not 0, status.sh not "Overall: OK", or any line after "--- open alerts:": include in the handoff the
     "!!" lines and every open alert line (this chat report is the alert channel). If Main already
     reported the same problem in its run today, say so in one line instead of repeating details.
3. Read <REPO>/staging/server-export/INDEX.md and include rows with "gap" or warnings.

ALWAYS end with a result to the parent chat whose first line is exactly:
EXPORT NOT DONE IN SCHEDULED RUN — parent: run the export loop now
Then one line per health problem found (or "health: OK"), followed by any memory/age/INDEX problems.
No logs, no message content, no secrets. This handoff is required on every run, healthy or not.
```

## Parent chat: export loop
On every handoff (or at any time), Assist's normal chat follows these steps in order. Keep the
same safety rules, use `write_to_file: true`, and report to the owner only on problems, including
all problems from the handoff. Paging may go to a subagent only if it has ReadTranscript: an
automation/scheduled subagent does not; a normal executor subagent started from the chat does.
Skip deleted ids throughout (DELETED_BOTS_FILE, default /home/box/agent-data/deleted-agents.json).

```text
1. Export GrokBox-Main and the primary chat: call ReadTranscript {in: <MAIN_ID>, limit: 200} and
   ReadTranscript {in: <PRIMARY_ID>, limit: 200}, then
   rc=0; python3 <REPO>/server-export-merge.py ingest --remove <result files> || rc=$?; echo "ingest_rc=$rc"
   Judge the run by the printed ingest_rc line, never by the JSON. ingest_rc=3 means a page was
   rejected (kept, not ingested): refetch that id with a smaller page (limit: 100, then 50) -
   before=<value> if the JSON lists one for that id, otherwise its newest page (a rejected newest
   page leaves {} in the output) - and ingest the refetched file; once that reports ingest_rc=0,
   delete the rejected file it replaces (a kept rejected file makes every later ingest exit 3
   again). A page rejected twice is skipped today, both result files deleted, and reported
   ("<id>: transcript page rejected twice"). Tomorrow's run fetches the newest page again, so
   nothing is lost.
   For each "id": N it prints, call ReadTranscript {in: id, limit: 200, before: N} ("newest": without before)
   and ingest only those new files, until ingest_rc=0 and it prints {} (at most 30 rounds). Only
   follow ids <MAIN_ID> and
   <PRIMARY_ID>; other ids in the output are Main's job (step 2 checks them).
2. Fallback for Main: run
   python3 <REPO>/server-export-merge.py age --max-hours 26 <every non-deleted id in AGENTS_DIR except ASSIST_ID>
   Export every stale bot using Main's B1–B3 loop (docs/routine-main.md), skipping deleted ids.
3. Assist's own row (<ASSIST_ID>) is normally exported only by Main. Check:
   python3 <REPO>/server-export-merge.py age --max-hours 26 <ASSIST_ID>
   If it exits 1, FIRST report to the owner exactly:
   "GrokBox-Main's daily export did not run; GrokBox-Assist covered it"
   Keep that alert visible. Only AFTER reporting, export your own row using Main's B1–B3 loop too.
   This self-export is partial (only the current run) and does not replace Main's export.
   It refreshes Assist's checked timestamp, silencing roster and freshness alerts until Main runs
   again; that is why reporting the miss first is required.
   Never export your own row silently; report any unreadable result or remaining gap.
4. Read INDEX.md for gaps/warnings, then run cd <REPO> && ./export-freshness.sh.
   It must print "daily export OK"; otherwise report the problem.
```

## First run
After creating the scheduled routine, run health and memory steps once. Run the first full export
of Main and the primary chat in the normal chat, using the parent loop above.
