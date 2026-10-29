# Server-side export: all bots' conversations + memory into the backup

A box backup only contains the box's synced local copy of transcripts. The authoritative server copy of
each bot's conversation, and the bots' + owner's shared memory, can only be read with the Grok Bot
tools `ReadTranscript` and `RecallMemory`. **These are bot tools, not programs: cron / `scheduler.sh`
cannot call them.** Scheduled runs also lack ReadTranscript and cannot talk to the owner. They export
memory with RecallMemory and always hand off to their parent chats. Those chats ([bots.md](bots.md)) pull the pages, and
`server-export-merge.py` merges them into `staging/server-export/`, which every snapshot already includes.
GrokBox-Main exports every bot except itself; GrokBox-Assist exports Main and the primary bot's main chat.
The script takes a lock, so both bots may run it at the same time.
The tool result formats and platform paths it relies on are listed in [platform-contract.md](platform-contract.md).

## Layout (dirs 700, files 600)
| path | what |
|---|---|
| `transcripts/<agent-id>__<slug>.jsonl` | one conversation, oldest first, one JSON message per line |
| `state/positions.json` | per id: name, server total, highest exported position, exported byte length, lines, last export, pending pages, warnings |
| `state/pending/<id>/<A>-<B>.jsonl` | pages not yet contiguous with what is exported |
| `INDEX.md` | name, id, counts, last export, status (`complete`, `empty`, `not readable`, `gap`) |
| `memory/<name>.md` | deduplicated RecallMemory facts per bot, a **sample** (see "Memory export is a sample") (`grokbox-main-and-shared`, `grokbox-assist-and-shared`, `primary-bot-private`); only grows |
| `state/replaced/` | originals kept by `repair` (renamed-bot split files) and `dedupe` (adjacent repeated blocks) |

Set `SERVER_EXPORT_DIR` to write elsewhere and `AGENTS_DIR` if the agents live somewhere other than
`/home/box/agent-data/agents` (used only to look up display names).

## How pages are merged
`ReadTranscript` returns at most ~48 KB per call, with a header `positions A–B of N`, newest page first,
and you page back with `before=A`. Positions and lines are not 1:1 (several tool results can share one
position), so the script stitches pages by position range and de-duplicates an overlapping page by
matching the longest suffix of the exported file against the page's head. Re-ingesting a page is a no-op,
so an interrupted run can be repeated. Pending pages are written atomically (temp file + fsync +
rename). The transcript file is either appended in place with one fsynced write (a page that continues
the export exactly) or rewritten via temp file + rename; the exported byte length is recorded in
`positions.json`, and the next run first cuts the file back to that recorded length, so a run killed
mid-write never leaves a half-written line or a duplicated page behind.

## Daily routines
The ready-to-paste prompts are [routine-main.md](routine-main.md) (scheduled health + memory + handoff; parent chat exports all other bots) and
[routine-assist.md](routine-assist.md) (scheduled health + memory + handoff; parent chat exports Main + the primary chat and watches Main). Setup:
[../AGENTS.md](../AGENTS.md) step 10. Store only each template's **Scheduled run** prompt in UpdateRoutine.
Every run returns its explicit EXPORT NOT DONE handoff, even when healthy. Steps 1–3 below run in
the **parent chat**, never the scheduled run; steps 4–6 can run in the schedule. After paging, the
chat checks INDEX.md and requires `./export-freshness.sh` to print OK. Only problems go to the owner.
The shared steps:
1. Call `ReadTranscript {in: <id>, limit: 200}` for each id to export (newest page), in parallel, `write_to_file: true`.
2. `python3 <repo>/server-export-merge.py ingest --remove <result files>` — **check the exit code, not
   the printed JSON**. In a bot's shell the exit code must be made visible, because `|| rc=$?` alone
   leaves the shell's own status 0:
   `rc=0; python3 <repo>/server-export-merge.py ingest --remove <files> || rc=$?; echo "ingest_rc=$rc"`.
   `ingest_rc=0` = every page was ingested; the printed
   `{id: before}` then says what to fetch next, `{}` = everything complete. `ingest_rc=3` = at least
   one page was rejected (invalid JSON lines, unreadable, or no transcript header): the file is kept,
   its range is NOT recorded as exported. Refetch each rejected id with a smaller page (`limit: 100`,
   then `limit: 50`): `before=<value>` if the JSON output lists one for that id, otherwise its newest
   page (a rejected newest page leaves `{}` in the output — the exit code is the only signal). Once a
   refetch reports `ingest_rc=0`, delete the rejected result file it replaces (a kept rejected file
   makes every later ingest exit 3 again). If the retry is rejected too, skip that id for today and
   report it in the run report. Nothing is lost: tomorrow's run always fetches the newest page again,
   and a rejected gap keeps reappearing in `next`'s output. For a result that says "No conversation
   ... has the id", ingest it with `--id <id>` so it is recorded as not readable.
3. For each `id: N` call `ReadTranscript {in: id, limit: 200, before: N}` (`"newest"`: without `before`),
   then ingest only those new result files (step 2). Repeat until `ingest_rc=0` and `{}`. For long
   backlogs you may fire `before: N, N-35, N-70, ...` in parallel; overlaps are de-duplicated and any
   gap reappears in the output. Stop after 30 rounds and report if not done.
4. `RecallMemory` with generic queries (a sample, not a full dump: see below), then
   `server-export-merge.py memory --remove --out <bot>-and-shared --label <bot> <files>` (at most ~15 facts per query).
   Use `write_to_file: true` if the tool offers it. Some bots' RecallMemory has no such option and returns the
   result inline: then paste each result **verbatim** into a file with a quoted heredoc (one Shell call per
   result), `cat > /workspace/agent-tools/<bot>-mem-<n>.txt <<'GROKBOX_MEM_END_7Q2'` ... `GROKBOX_MEM_END_7Q2`, and pass those files.
   The quoted delimiter stops the shell from expanding `$`, backticks or `\` in the facts; an unusual
   delimiter (not `EOF`) cannot end the heredoc early, and a per-bot file name keeps two bots running at
   the same time from overwriting each other's files. `--remove` deletes them afterwards.
5. `server-export-merge.py age --max-hours 26 <partner-covered ids>`: exit 1 = the partner's export is missing.
6. Check `INDEX.md`: no `gap` rows and no warnings. The next hourly snapshot picks everything up.

`./export-freshness.sh` requires every active bot's `checked` time within `EXPORT_MISSED_HOURS`
(default 26; 0 disables); unknown times are stale. Deleted, retired and unreadable bots are ignored.
`./export-freshness.sh --warnings` lists active bots with INDEX warnings; doctor's "export warnings"
row shows WARN for these without raising alerts. Review the details in `staging/server-export/INDEX.md`.
Run `./expected-bots.sh --suggest`, review the array, and paste it into local `config.env`.
Doctor warns about an empty roster once active exports exist; `EXPECTED_BOTS_REQUIRED=0` silences it.

A bot that is renamed keeps one file: the transcript file is renamed to the new slug. `repair` merges files
that older versions split; it keeps the originals in `state/replaced/`.

## One-time cleanup of repeated transcript lines

Older versions could append an overlapping page whole when a user message started with
`<memory_context>`. The server rebuilds or omits that message on each fetch, so exact matching failed and
stored a persistent `overlap … matched no lines; appended page whole` warning. Incremental exports
now try exact matching first, then ignore volatile `memory_context` lines when comparing, requiring
an ordinary matching line. A refreshed duplicate of a trailing volatile line can be dropped; a new
volatile line after a match ending in an ordinary line is kept. A memory-context-only match is
never sufficient for that fallback. Only user messages consisting entirely of text parts that
each start with `<memory_context>` are volatile, and each part must either have no closing
`</memory_context>` (truncated), or have only whitespace and zero or more system blocks after
its first closing tag. Each block must be `<NAME ...>...</NAME>`, with NAME exactly
`available_subagent_models` or `teammates`, and ends at its first matching closing tag.
An unclosed final block consumes the rest of the part. After these blocks, an elided suffix
starting with `...` and ending (ignoring trailing whitespace) with `</teammates>` is also
allowed if it contains no other `<` characters. Otherwise, only whitespace may occur outside
these blocks; any other text (such as a user question after a closed block) or an unknown
block name makes the whole message ordinary, as do mixed parts. These messages are compared
exactly as canonical JSON.

Always run `dedupe --dry-run` first and check the reported line ranges against the warning's
time/position before applying cleanup. A genuine exact repeat anywhere in a flagged transcript
can also be removed. To review and clean up existing damage, run from the repository:

```bash
python3 server-export-merge.py dedupe --dry-run       # reports only; writes nothing
python3 server-export-merge.py dedupe                # or dedupe ID... to select transcripts
```

Only ids with a `matched no lines` warning are eligible. Cleanup removes the **second** copy of
an immediately repeated block of at least five ordinary lines with at least three distinct lines,
ignoring volatile `memory_context` lines when comparing. It removes the span from the second copy's
first to last ordinary line, including volatile lines inside it. Directly following volatile lines
are dropped only up to the number between the two copies, so a refreshed duplicate can be dropped.
All other lines and their order remain intact. Originals
are retained in `staging/server-export/state/replaced/<timestamp>/`. Only when lines were removed
does it clear that id's `matched no lines` warnings, update line/byte counts, add a note, and refresh
`INDEX.md`; unrelated warnings remain. Short, low-diversity or nonadjacent repeats are left for review.
Repeated runs make no further changes. Both modes print one summary line per selected id to stderr
and JSON to stdout, including the original one-based line numbers removed (or proposed for removal).
Blank and non-JSON lines match only their raw text. Each changed id saves `positions.json` and
`INDEX.md` immediately. A failing id is reported on stderr and with `status: "error: ..."` in JSON;
other ids are still processed, and the command exits 1 if any id failed.

## Memory export is a sample
The memory export is **not** a complete dump of a bot's memory. Each run asks `RecallMemory` a fixed
set of generic queries (GrokBox-Main about 10, GrokBox-Assist 3-5; see the routine templates) and stores
whatever comes back, at most ~15 facts per query. Facts that no query happens to match are not in the
export. The files only grow (deduplicated, never pruned), so coverage improves over time, but a fact can
be missing. Keep anything important in a file under the backup roots too: those files are in every snapshot.

## Voice conversations
Voice calls happen on the platform's servers. As far as we have checked, a voice call shows up in the
bot's chat transcript like other messages, so the daily transcript export picks it up with the next
daily export (up to ~24 h later). Unknown: whether the stored text is verbatim or a summary, and how long
the server keeps it. Grok Box does not export audio.

## What it cannot reach
- a bot's own running conversation (that is why there are two bots), and subagent runs;
- agents the server does not (yet) let the bots read: recorded as `not readable`;
- private memory of bots other than the two Grok Box bots. RecallMemory only sees the caller's own and the
  shared memory. The primary bot exports its own once at setup or on request ([bots.md](bots.md)); other
  bots' on-box memory files are in the brain export;
- Pages/canvases (`ListCanvases` only shows a bot's own Pages).

### Deleted bots

The merger reads `DELETED_BOTS_FILE` from the environment (default
`/home/box/agent-data/deleted-agents.json`; `""` disables it), using the same tolerant parsing as
`expected-bots.sh`. Export this variable when overriding it for the merger; the Python command
does not source `config.env`. Missing, empty, invalid or directory paths mean no deleted ids.

`ingest`, `index` and `repair` refresh a boolean `deleted: true` in `state/positions.json`, removing it when
an id leaves the list. The stored `name` remains the original raw name. `INDEX.md` displays
“Name (deleted)” (only one suffix), with status “deleted, history kept (complete)” or
“deleted, history kept (K of N messages, export incomplete)”. Previously exported history that is no longer readable shows
“deleted, history kept (K messages, no longer readable)”. A known positive total with nothing kept
shows “deleted, nothing exported (0 of N messages)”; empty or unreadable records with nothing kept
and no known positive total show “deleted before first export”. `next` skips deleted ids because they cannot be read.

Transcript filenames stay unchanged on deletion. Renaming them would churn paths across snapshots
and require care with restore/positions consistency. The label in `INDEX.md` and flag in
`positions.json` already identify deleted bots; each transcript stays restorable under its id.
