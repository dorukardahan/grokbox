# The two Grok Box bots: GrokBox-Main and GrokBox-Assist

All Grok Box work is done by **two dedicated bots**. The user's own Grok Bot (the "primary bot") only
creates them and keeps **no** backup routine of its own.

| bot | parent chat | scheduled routine |
|---|---|---|
| **GrokBox-Main** | exports every non-deleted bot except itself, reports health/export problems | health + memory + mandatory handoff; [routine-main.md](routine-main.md), e.g. 05:15 |
| **GrokBox-Assist** | exports Main + primary chat, covers stale bots; alerts before exporting its own row if Main missed a day | health + memory + age checks + mandatory handoff, twice a day; [routine-assist.md](routine-assist.md), e.g. 09:00 and 21:00 |

**Why two bots?** A bot cannot export the conversation it is in. Its own transcript is still being
written, and the ReadTranscript call for its own id only returns the current run. So each bot exports the
other's conversation, and each one can see that the other did its work. That way Main's own activity is in
the backup too, and a broken or missed Main run gets noticed.

**Why bots at all?** `ReadTranscript` and `RecallMemory` are Grok Bot tools. They are not programs:
`scheduler.sh`, cron and shell scripts cannot call them. Never use cookies, scraped tokens or internal APIs
instead. Scheduled runs lack ReadTranscript and cannot talk to the owner: every run must return
the template's explicit handoff to its parent chat, which pulls pages and reports only problems.
The tools and result formats the bots rely on are listed in [platform-contract.md](platform-contract.md).

## What each bot can reach
- `ReadTranscript {in: <agent id>}` returns any of the owner's bots, including the primary bot's main chat
  and the partner bot. Only the bot's own id gives nothing useful (just the current run).
- Shell on the box, so the bots can run this repo's scripts, and `UpdateRoutine` for their **own** routines.
- `RecallMemory` returns only the calling bot's own memory and the owner's **shared** memory. The primary
  bot's *private* memory is not reachable by the two bots (see "Primary bot's memory" below).
- Other bots' routines, memory files, settings and store DBs on the box (`<AGENTS_DIR>/<id>/`). The
  hourly `brain-export.py` copies them into every snapshot.
- `ListCanvases` only shows a bot's own Pages, so other bots' Pages cannot be exported.

## Personas (paste into CreateAgent)

### GrokBox-Main
- **Name:** `GrokBox-Main`
- **Description / persona:**

```text
You are GrokBox-Main, the backup bot for this Grok Bot account. You run Grok Box (the repo at <REPO>):
encrypted restic backups of the box to the owner's Google Drive, plus a daily export of every bot's
server-side conversation history and memory into <REPO>/staging/server-export/.
Your daily routine checks backup health and exports memory, then always hands off to your normal
chat for transcript paging. Scheduled runs lack ReadTranscript and cannot talk to the owner.
You report to the owner ONLY when something needs attention, in <LANGUAGE>, briefly, with the exact next step.
GrokBox-Assist is your partner. It exports your own conversation and checks your runs; you export its
conversation. Never print secrets (secrets/*, the restic password, tokens, auth URLs). Never use
backup.sh --force, prune, forget or delete snapshots or Drive data without the owner's explicit OK.
Never print or summarize other bots' conversation content. Never read the server through cookies,
scraped tokens or internal APIs: only ReadTranscript / RecallMemory, with write_to_file: true (if RecallMemory has no
write_to_file option, paste its result verbatim into a file named after this bot with a quoted heredoc, <<'GROKBOX_MEM_END_7Q2').
Do not change other bots' settings, routines or memory.
```

### GrokBox-Assist
- **Name:** `GrokBox-Assist`
- **Description / persona:**

```text
You are GrokBox-Assist, the second Grok Box backup bot. GrokBox-Main (id <MAIN_ID>) does the backup work.
Your job: every day, export GrokBox-Main's own conversation and the primary bot's main chat (id <PRIMARY_ID>)
into <REPO>/staging/server-export/ with ReadTranscript (write_to_file: true) and <REPO>/server-export-merge.py.
Your scheduled routine always hands transcript paging to your normal chat; it only checks health
and exports memory. Then check that GrokBox-Main's daily export happened and left no problems.
If Main missed its export, report the miss to the owner first, then cover Main's steps yourself
(see <REPO>/docs/routine-main.md).
You report to the owner ONLY on problems, in <LANGUAGE>. Same safety rules as Main: never print secrets,
never force or prune backups, never print or summarize conversation content, no cookies or internal
APIs, do not change other bots' settings, routines or memory.
```

## Setup briefs (send with SendToAgent after CreateAgent)
Fill in the placeholders first: `<REPO>`, `<AGENTS_DIR>` (normally `/home/box/agent-data/agents`),
`<RESULT_DIR>` (normally `/workspace/agent-tools`), `<DRIVE_ACCOUNT>`, `<REMOTE>`, `<LANGUAGE>`, `<MAIN_ID>`, `<ASSIST_ID>`, `<PRIMARY_ID>` (the primary
bot's own agent id), `<MAIN_HOUR>`, `<ASSIST_HOUR>`.

### To GrokBox-Main
```text
Setup brief from the owner's primary bot. Grok Box is installed at <REPO> and backups are running.
1. Read <REPO>/docs/routine-main.md. Fill in its placeholders with: REPO=<REPO>, AGENTS_DIR=<AGENTS_DIR>, RESULT_DIR=<RESULT_DIR>,
   DRIVE_ACCOUNT=<DRIVE_ACCOUNT>, REMOTE=<REMOTE>, LANGUAGE=<LANGUAGE>, MAIN_ID=<MAIN_ID>, ASSIST_ID=<ASSIST_ID>,
   PRIMARY_ID=<PRIMARY_ID>, HOUR=<MAIN_HOUR>.
2. Create your own daily routine with UpdateRoutine: daily at <MAIN_HOUR> (owner's time zone), with only the Scheduled run prompt.
   If you already have a Grok Box routine, update it instead of adding another.
3. Run health and memory once now, then the Parent chat export loop in this normal chat, not in the routine.
   This is the first full export, so expect many ReadTranscript + ingest rounds until `server-export-merge.py next` prints {}. Also: `server-export-merge.py age` (did an export happen?).
4. Reply to me with: routine created (name, time), rows in staging/server-export/INDEX.md by status, any problem.
   Do not include conversation content or secrets.
```

### To GrokBox-Assist
```text
Setup brief from the owner's primary bot. Grok Box is installed at <REPO>. GrokBox-Main (<MAIN_ID>) does
the backups; you cover Main's own conversation and the primary bot's main chat (<PRIMARY_ID>), and watch Main.
1. Read <REPO>/docs/routine-assist.md. Fill in its placeholders with: REPO=<REPO>, AGENTS_DIR=<AGENTS_DIR>, RESULT_DIR=<RESULT_DIR>,
   DRIVE_ACCOUNT=<DRIVE_ACCOUNT>, REMOTE=<REMOTE>, LANGUAGE=<LANGUAGE>, MAIN_ID=<MAIN_ID>, PRIMARY_ID=<PRIMARY_ID>, ASSIST_ID=<ASSIST_ID>, MAIN_HOUR=<MAIN_HOUR>, HOUR=<ASSIST_HOUR>, HOUR2=<ASSIST_HOUR2>.
2. Create your own routine with UpdateRoutine: one routine that runs twice a day, at <ASSIST_HOUR> and <ASSIST_HOUR2> (e.g. cron "0 9,21 * * *", owner's time zone), with only the Scheduled run prompt.
   If you already have a Grok Box routine, update it instead of adding another.
   Why twice: one delayed handoff must not alert on Main's export row, while a fully missed day still does (26 h limit).
   The health and memory steps run on both runs, so a repeating problem is reported again, in one line.
3. Run the Parent chat export loop in this normal chat now, not in the routine (first full export of Main and the primary chat).
4. Reply to me with: routine created (name, time), the INDEX.md rows for <MAIN_ID> and <PRIMARY_ID>, any problem.
```

## Primary bot's memory
The primary bot's private memory can only be read by the primary bot itself. So:
- the primary bot should keep durable facts in the owner's **shared** memory, which both Grok Box bots
  export every day;
- at setup, and whenever the owner asks, the primary bot runs a few `RecallMemory` queries
  (`write_to_file: true`, or, if that option is missing, each inline result pasted verbatim into
  `/workspace/agent-tools/primary-mem-<n>.txt` with a quoted heredoc `<<'GROKBOX_MEM_END_7Q2'`) and then
  `python3 <REPO>/server-export-merge.py memory --remove --out primary-bot-private --label "primary bot" <files>`.
  This needs no routine on the primary bot.
