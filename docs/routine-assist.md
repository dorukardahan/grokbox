# GrokBox-Assist daily routine (exports Main + primary chat, watches Main)

GrokBox-Assist owns this routine and creates it itself with `UpdateRoutine`. It runs a few hours after
GrokBox-Main ([routine-main.md](routine-main.md)) and does three things:
1. Exports **GrokBox-Main's own conversation**, which Main cannot export itself.
2. Exports the **primary bot's main chat** (Main exports it too; two copies are merged without duplicates).
3. Checks that Main's daily run happened and found no problems. If Main missed its run, Assist does
   Main's steps itself.

Background: [bots.md](bots.md).

## Placeholders
Same as [routine-main.md](routine-main.md): `<REPO>`, `<AGENTS_DIR>`, `<DRIVE_ACCOUNT>`, `<REMOTE>`,
`<LANGUAGE>`, `<MAIN_ID>`, `<ASSIST_ID>`, `<PRIMARY_ID>`. In addition:
- `<MAIN_HOUR>`: when Main runs.
- `<HOUR>`: when this routine runs, e.g. `09:00` if Main runs at `05:15`.

## Routine settings
- **Name:** `GrokBox-Assist daily: export Main + primary chat, watch Main`
- **Schedule:** daily at `<HOUR>` (owner's time zone), at least 2 hours after `<MAIN_HOUR>`.
- **Report:** only on problems, in `<LANGUAGE>`.

## Prompt
```text
GrokBox-Assist daily run. Repo at <REPO>. Report to the owner ONLY on problems, in <LANGUAGE>.
Rules: never print secrets; never use backup.sh --force; never prune/forget/delete snapshots or Drive data;
never print or summarize conversation content; always use write_to_file: true for ReadTranscript (and for
RecallMemory when it offers it); delete only result files you created; no cookies, scraped tokens or internal APIs;
do not change other bots' settings, routines or memory.

1. Export GrokBox-Main and the primary chat: call ReadTranscript {in: <MAIN_ID>, limit: 200} and
   ReadTranscript {in: <PRIMARY_ID>, limit: 200}, then
   python3 <REPO>/server-export-merge.py ingest --remove <result files>
   For each "id": N it prints, call ReadTranscript {in: id, limit: 200, before: N} ("newest": without before)
   and ingest again, until it prints {} (at most 30 rounds). Only follow ids <MAIN_ID> and <PRIMARY_ID>;
   other ids in the output are Main's job (step 3 checks them).
2. Memory: RecallMemory with 3-5 generic queries ("user preferences", "projects", "decisions", "this week"),
   then: python3 <REPO>/server-export-merge.py memory --remove --out grokbox-assist-and-shared --label GrokBox-Assist <files>
   If RecallMemory has no write_to_file option (it then returns the result inline), paste each result
   VERBATIM into its own file with a quoted heredoc, one Shell call per result, e.g.
   cat > /workspace/agent-tools/grokbox-assist-mem-1.txt <<'GROKBOX_MEM_END_7Q2'
   <the RecallMemory result, unchanged>
   GROKBOX_MEM_END_7Q2
   (numbered -1, -2, ...; the odd end marker cannot appear inside a result) and pass those files instead.
   Never edit, summarize or add facts.
3. Scheduler self-heal + health, EVERY run (not only when Main missed its run):
   cd <REPO> && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"; echo "--- open alerts:"; cat state/ALERT 2>/dev/null
   (install.sh --schedule is a no-op when the scheduler runs; after a box move it starts it again.)
   Then: did Main run today? python3 <REPO>/server-export-merge.py age --max-hours 26 <ASSIST_ID>
   (Main exports this bot every run, so this is the age of Main's last export).
   - Exit 1 from age (Main's export is older than 26 h): Main missed its run. Do Main's routine yourself
     (<REPO>/docs/routine-main.md, Part A and Part B, with your own id <ASSIST_ID> in place of the skipped
     id, so you export everything except yourself) and report "GrokBox-Main did not run; GrokBox-Assist
     covered it".
   - schedule_rc not 0, status.sh not "Overall: OK", or any line after "--- open alerts:": report the
     "!!" lines and every open alert line (this chat report is the alert channel). If Main already
     reported the same problem in its run today, say so in one line instead of repeating details.
4. Read <REPO>/staging/server-export/INDEX.md and report rows with "gap" or warnings.

Report format, only when something needs attention: one short list with the exact next step.
No logs, no message content, no secrets.
```

## First run
Right after creating the routine, run steps 1 and 2 once. This is the first full export of Main's and
the primary bot's conversations.
