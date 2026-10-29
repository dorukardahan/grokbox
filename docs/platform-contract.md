# Platform contract: what Grok Box assumes from the Grok Bot platform

Grok Box is plain bash + Python, but some parts depend on how the Grok Bot platform behaves. This page
lists those assumptions, as read from the code (`server-export-merge.py`, `brain-export.py`,
`expected-bots.sh`, `export-freshness.sh`, `lib.sh`, `config.env.example`) and the bot docs
([bots.md](bots.md), [server-export.md](server-export.md), [routine-main.md](routine-main.md),
[routine-assist.md](routine-assist.md)). The platform does not publish a contract for these formats; if
it changes them, the parts below are what breaks.

## a. ReadTranscript result files
The bots call `ReadTranscript {in: <id>, limit: 200}` (newest page) and page back with
`before: <A>`, using `write_to_file: true`. `server-export-merge.py ingest` reads each result file like this:

| part | what the parser expects |
|---|---|
| header | text **before the first message line** containing `Transcript of agent "<name>" (<id>), positions A–B of N` (also `conversation` or no word before the name; quotes optional; en dash or hyphen). Only the header area is searched, never message bodies. |
| header without name/id | `positions A–B of N` alone is accepted when the caller passes `--id <id>` |
| messages | every line that starts with `{` is one message and must be valid JSON. One invalid JSON line rejects the whole file (exit 3, file kept). Other lines are ignored. |
| positions | `A`–`B` is the inclusive range of this page, `N` the server total. Positions and lines are not 1:1 (several tool results can share one position), so overlaps are de-duplicated by content. |
| unreadable id | a result containing `No conversation, agent, or subagent` and no messages, ingested with `--id <id>`, is recorded as `not readable` |
| empty | a header with `of 0` (server total 0), or a result with neither header nor messages ingested with `--id <id>`, is shown as `empty` |
| no header, no `--id` | the file cannot be attributed to a bot: rejected (exit 3, file kept) |

Paging: the next call for an id is `before: <A of the oldest pending page>`, or the newest page
(`"newest"`) when the server total grew. Page size: the docs say a call returns at most ~48 KB; the
routines ask for `limit: 200` and fall back to `limit: 100`, then `50`, when a page is rejected.
These limits come from observation, not from a published spec.

## b. RecallMemory result files
`server-export-merge.py memory` reads RecallMemory results (written with `write_to_file: true`, or
pasted verbatim into a file with a quoted heredoc when that option is missing):

- a fact is a line starting with `- (`; following lines that start with two spaces are joined to it;
- an optional line like `Top <k> matches for "<query>" ... (<total>` is used only for the printed totals;
- everything else is ignored. Facts are deduplicated as whole lines and never removed.

RecallMemory returns only the caller's own memory plus the owner's shared memory, at most ~15 facts per
query (as documented in [server-export.md](server-export.md)). The export is therefore a **sample**
from about 10 generic queries (Main) or 3-5 (Assist), not a complete dump.

## c. Deleted bots file (`DELETED_BOTS_FILE`)
Default `/home/box/agent-data/deleted-agents.json`; `""` disables it. `server-export-merge.py`,
`expected-bots.sh` and `export-freshness.sh` parse it the same way. Accepted shapes:

| shape | ids taken |
|---|---|
| `["abcdef12", "bot-b-id"]` | every string |
| `[{"id": "abcdef12", ...}, ...]` | each object's `id` (if it is a string) |
| `{"abcdef12": {...}, "bot-b-id": {...}}` | every key whose value is an object |
| `{"agents": <one of the shapes above>}` | the same rules applied to `agents` |

A missing, empty, invalid or unreadable file (or a directory) means "no deleted bots"; nothing fails.
Grok Box only reads this file and never writes it. Who writes it is not verified: we assume the
platform maintains it when a bot is deleted. If your platform has no such file, list retired bots in
`RETIRED_BOTS` in `config.env` instead.

## d. Agents directory (`AGENTS_DIR`)
Default `/home/box/agent-data/agents`. Expected layout: one directory per bot, named by its agent id,
with an optional `profile.json` that has a string `name`:

```text
<AGENTS_DIR>/
  abcdef12/profile.json     {"name": "bot-a", ...}
  bot-b-id/                 (no profile.json: shown by id)
  some-file.json            (files are skipped)
```
Used for: display names when a transcript header has none (merger), the list of ids GrokBox-Main
exports (routine B1), and spotting same-name replacements of deleted bots (`expected-bots.sh`). A
missing directory or profile is tolerated.

## e. Bot tools the routines use
Only these, as named in the bot docs:

| tool | used for |
|---|---|
| `CreateAgent` | the primary bot creates GrokBox-Main and GrokBox-Assist |
| `SendToAgent` | the primary bot sends each the setup brief |
| `UpdateRoutine` | each Grok Box bot creates its own daily scheduled routine |
| `ReadTranscript` (with `write_to_file`) | transcript pages; only in a normal (parent) chat, not in scheduled runs |
| `RecallMemory` (`write_to_file` optional) | memory sample; works in scheduled runs |
| Shell on the box | running this repo's scripts and writing result files |
| subagents (optional) | paging may go to a normal executor subagent that has ReadTranscript |

Also assumed: a scheduled run returns a result to the bot's parent chat (the handoff), cannot talk to
the owner, and cannot read the conversation it runs in. `ListCanvases` is mentioned only as a limit
(it shows a bot's own Pages).

## f. Box layout and platform paths (defaults in `config.env.example`)
| setting | default | used by |
|---|---|---|
| `BACKUP_ROOTS` | `(/workspace /home/box)` | what is backed up (the persistent part of the box) |
| `AGENTS_DIR` | `/home/box/agent-data/agents` | see d. |
| `DELETED_BOTS_FILE` | `/home/box/agent-data/deleted-agents.json` | see c. |
| `BRAIN_AGENT_DIRS` | `(/home/box/agent-data /home/box/sand-data)` | brain export index |
| `STORES_GLOB` | `/cursor/stores/*` | brain export mirrors mounted agent stores outside the roots |
| `SQLITE_GLOBS` | databases under `/home/box/agent-data`, `/home/box/sand-data`, `/cursor/stores` | consistent SQLite copies |
| `HYDRATION_LOG` / `HYDRATION_OK_PATTERN` | `/tmp/sand-copy-in.log` / `outcome=hydrated` | skip backups while a moved box is still being filled |
| `TEST_RESTORE_PATHS` | `(/home/box/agent-data /home/box/sand-data)` | always part of the test-restore sample |

The agent, store, SQLite, hydration and test-restore paths may be missing; the scripts then skip that
part (the brain export reports "none"). Point `BACKUP_ROOTS` at folders that exist (what happens with
a missing root is not verified here).

## g. Not guaranteed / unknown
- How long the platform keeps conversations and memory on its servers: unknown.
- Voice calls: as far as we have checked they appear in the chat transcript. Whether that text is
  verbatim or a summary: unknown. Retention: unknown.
- Rate limits for `ReadTranscript` / `RecallMemory`: unknown. The routines cap paging at 30 rounds.
- The exact header wording, the ~48 KB page limit and the ~15 facts per memory query are observed
  behaviour, not a published API; a platform change can break parsing (the merger then rejects pages
  with exit 3 instead of losing data).
- Which bots the server lets another bot read: some are reported `not readable`.

## Using Grok Box without a Grok Bot
Backup, restore, `doctor.sh`, `status.sh`, the scheduler and the test restores work on any Linux box.
To run there:
1. Set `BACKUP_ROOTS` (and `QUICK_ROOTS` if you changed it separately) to your own folders, and
   `RESTORE_BASE` to a writable folder.
2. Do not create GrokBox-Main / GrokBox-Assist; skip AGENTS.md step 10 and the routine templates.
3. Keep `EXPECTED_BOTS=()` (the default) and set `EXPORT_MISSED_HOURS=0`, so no export alert fires.
4. Brain export: set `BRAIN_AGENT_DIRS=()` and point `STORES_GLOB` at a path that does not exist (or
   leave the defaults: missing paths are reported as "none").
5. Adjust `SQLITE_GLOBS` to your own databases (or `()`), `TEST_RESTORE_PATHS` to something you
   care about, and set `HYDRATION_LOG=""`.
6. Optionally `DELETED_BOTS_FILE=""`.
