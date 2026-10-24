# Server-side export: all bots' conversations + memory into the backup

A box backup only contains the box's synced local copy of transcripts. The authoritative server copy of
each bot's conversation, and the primary bot's + owner's shared memory, can only be read with the Grok Bot
tools `ReadTranscript` and `RecallMemory`. **These are bot tools, not programs: cron / `scheduler.sh`
cannot call them.** So a daily routine of the primary bot pulls the pages, and `server-export-merge.py`
merges them into `staging/server-export/`, which every snapshot already includes.

## Layout (dirs 700, files 600)
| path | what |
|---|---|
| `transcripts/<agent-id>__<slug>.jsonl` | one conversation, oldest first, one JSON message per line |
| `state/positions.json` | per id: name, server total, highest exported position, lines, last export, pending pages, warnings |
| `state/pending/<id>/<A>-<B>.jsonl` | pages not yet contiguous with what is exported |
| `INDEX.md` | name, id, counts, last export, status (`complete`, `empty`, `not readable`, `gap`) |
| `memory/primary-bot-and-shared.md` | deduplicated RecallMemory facts; only grows |

Set `SERVER_EXPORT_DIR` to write elsewhere and `AGENTS_DIR` if the agents live somewhere other than
`/home/box/agent-data/agents` (used only to look up display names).

## How pages are merged
`ReadTranscript` returns at most ~48 KB per call, with a header `positions A–B of N`, newest page first,
and you page back with `before=A`. Positions and lines are not 1:1 (several tool results can share one
position), so the script stitches pages by position range and de-duplicates an overlapping page by
matching the longest suffix of the exported file against the page's head. Re-ingesting a page is a no-op,
so an interrupted run can be repeated.

## Daily routine (primary bot; always `write_to_file: true`, never print the content)
1. For every directory `<id>` in the agents dir, call `ReadTranscript {in: <id>, limit: 200}` (newest page).
   The calls can run in parallel.
2. `python3 <repo>/server-export-merge.py ingest --remove <result files>`. For a result that says
   "No conversation ... has the id", ingest it with `--id <id>` so it is recorded as not readable.
   The script prints `{id: before}`; `{}` = everything complete.
3. For each `id: N` call `ReadTranscript {in: id, limit: 200, before: N}` (`"newest"`: without `before`),
   then ingest again. Repeat until `{}`. For long backlogs you may fire `before: N, N-35, N-70, ...` in
   parallel; overlaps are de-duplicated and any gap reappears in the output.
4. Run `RecallMemory` with ~10 generic queries (preferences, projects, bots, routines, accounts, decisions,
   this week, the month name...), `write_to_file: true`, then `server-export-merge.py memory --remove <files>`.
   Each query returns at most ~15 facts.
5. Check `INDEX.md`: no `gap` rows and no warnings. The next hourly snapshot picks everything up.

## What it cannot reach
- the primary bot's own main chat (`in=session` only returns the routine's own run) and its subagent runs;
- agents the server does not (yet) let the primary bot read: recorded as `not readable`;
- other bots' private memory (RecallMemory only sees the primary bot's and the shared memory); their on-box
  memory files are in the brain export.
