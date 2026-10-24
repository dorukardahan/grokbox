# Server-side export: all bots' conversations + memory into the backup

A box backup only contains the box's synced local copy of transcripts. The authoritative server copy of
each bot's conversation, and the bots' + owner's shared memory, can only be read with the Grok Bot
tools `ReadTranscript` and `RecallMemory`. **These are bot tools, not programs: cron / `scheduler.sh`
cannot call them.** So the daily routines of the two Grok Box bots ([bots.md](bots.md)) pull the pages, and
`server-export-merge.py` merges them into `staging/server-export/`, which every snapshot already includes.
GrokBox-Main exports every bot except itself; GrokBox-Assist exports Main and the primary bot's main chat.
The script takes a lock, so both bots may run it at the same time.

## Layout (dirs 700, files 600)
| path | what |
|---|---|
| `transcripts/<agent-id>__<slug>.jsonl` | one conversation, oldest first, one JSON message per line |
| `state/positions.json` | per id: name, server total, highest exported position, lines, last export, pending pages, warnings |
| `state/pending/<id>/<A>-<B>.jsonl` | pages not yet contiguous with what is exported |
| `INDEX.md` | name, id, counts, last export, status (`complete`, `empty`, `not readable`, `gap`) |
| `memory/<name>.md` | deduplicated RecallMemory facts per bot (`grokbox-main-and-shared`, `grokbox-assist-and-shared`, `primary-bot-private`); only grows |
| `state/replaced/` | originals kept by `repair` (history of a renamed bot that older versions split into two files) |

Set `SERVER_EXPORT_DIR` to write elsewhere and `AGENTS_DIR` if the agents live somewhere other than
`/home/box/agent-data/agents` (used only to look up display names).

## How pages are merged
`ReadTranscript` returns at most ~48 KB per call, with a header `positions A–B of N`, newest page first,
and you page back with `before=A`. Positions and lines are not 1:1 (several tool results can share one
position), so the script stitches pages by position range and de-duplicates an overlapping page by
matching the longest suffix of the exported file against the page's head. Re-ingesting a page is a no-op,
so an interrupted run can be repeated.

## Daily routines
The ready-to-paste prompts are [routine-main.md](routine-main.md) (health + export of all bots) and
[routine-assist.md](routine-assist.md) (exports Main + the primary chat, watches Main). Setup:
[../AGENTS.md](../AGENTS.md) step 8. The export loop both use:
1. Call `ReadTranscript {in: <id>, limit: 200}` for each id to export (newest page), in parallel, `write_to_file: true`.
2. `python3 <repo>/server-export-merge.py ingest --remove <result files>`. For a result that says
   "No conversation ... has the id", ingest it with `--id <id>` so it is recorded as not readable.
   The script prints `{id: before}`; `{}` = everything complete.
3. For each `id: N` call `ReadTranscript {in: id, limit: 200, before: N}` (`"newest"`: without `before`),
   then ingest again. Repeat until `{}`. For long backlogs you may fire `before: N, N-35, N-70, ...` in
   parallel; overlaps are de-duplicated and any gap reappears in the output.
4. `RecallMemory` with generic queries, `write_to_file: true`, then
   `server-export-merge.py memory --remove --out <bot>-and-shared --label <bot> <files>` (at most ~15 facts per query).
5. `server-export-merge.py age --max-hours 30 <partner-covered ids>`: exit 1 = the partner's run is missing.
6. Check `INDEX.md`: no `gap` rows and no warnings. The next hourly snapshot picks everything up.

A bot that is renamed keeps one file: the transcript file is renamed to the new slug. `repair` merges files
that older versions split; it keeps the originals in `state/replaced/`.

## What it cannot reach
- a bot's own running conversation (that is why there are two bots), and subagent runs;
- agents the server does not (yet) let the bots read: recorded as `not readable`;
- private memory of bots other than the two Grok Box bots. RecallMemory only sees the caller's own and the
  shared memory. The primary bot exports its own once at setup or on request ([bots.md](bots.md)); other
  bots' on-box memory files are in the brain export;
- Pages/canvases (`ListCanvases` only shows a bot's own Pages).
