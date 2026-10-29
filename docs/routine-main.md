# GrokBox-Main daily routine (backup health + server export)

GrokBox-Main creates its daily routine with `UpdateRoutine`. The scheduled run checks health and
exports memory, then always hands transcript paging to its normal (parent) chat. Scheduled runs
have RecallMemory but no ReadTranscript and cannot talk to the owner. The parent chat reports only
problems. A second, hourly routine ([alert check](#alert-check-second-routine-hourly)) tells the owner
about new alerts the same day. Partner: [routine-assist.md](routine-assist.md); setup: [bots.md](bots.md).

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
| `<ALERT_CRON>` | schedule of the alert check, in the owner's time zone; avoid minutes :40 and :50 | `25 8-23 * * *` |
| `<HOUR>` | run time in the owner's time zone; keep it away from `check.sh` (04:40) | `05:15` |

## Routine settings
- **Name:** `GrokBox-Main daily: backup health + server export`
- **Schedule:** daily at `<HOUR>`. GrokBox-Assist runs a few hours later.
- **Result:** always return the parent-chat handoff. Only the parent chat reports problems to the owner, in `<LANGUAGE>`.
- **Second routine:** `GrokBox-Main alert check`, hourly. See [Alert check](#alert-check-second-routine-hourly).
  The daily routine stays as it is and keeps its own daily alert report.

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
After creating both routines, run health and memory steps once, and run B1–B3 and the
final check in the chat right away. The first export may need many paging rounds; later exports fetch what is new.

## Alert check (second routine, hourly)
This routine makes GrokBox-Main's chat the default alert channel. A new `state/ALERT` line or a new
`PROBLEM` row in `doctor.sh` reaches the owner within an hour, with no ntfy app, webhook or `ALERT_HOOK`.
The scheduler cannot do this itself: only a bot chat can write to the owner. Those three settings stay
available as extra channels ([health-and-alerts.md](health-and-alerts.md#get-alerts-to-a-human)).

Create it with `UpdateRoutine`, as a second routine next to the daily one. Do not fold it into the daily
prompt, which runs once a day. Each run only reads. It never acknowledges alerts, restarts the scheduler,
runs a backup, or edits `config.env`. The daily routine, its parent chat, and the owner do that.

- **Name:** `GrokBox-Main alert check`
- **Schedule:** `<ALERT_CRON>`, for example `25 8-23 * * *` (every hour from 08:25 to 23:25). Alerts
  raised overnight arrive at 08:25. Use `25 */2 * * *` to halve the number of runs. The watchdog alerts
  only after 3 h without a good backup, so a 2-hour cadence still reports a stalled backup the same day.
- **Result:** always return the handoff below. The parent chat writes to the owner only when the first
  line says there are new problems.

### How "new" is decided
`doctor.sh` exits 0, 1 or 2 for OK, WARN or PROBLEM, so its exit code cannot show a crash. The run treats
a doctor output without an `Overall:` line as a failure, so a broken doctor never looks like a healthy box.
The scheduled run collects the open problems into `state/alert-current.tsv`, one line per problem:
a key, a tab, and the text. An alert's key is its full `state/ALERT` line, which carries a timestamp.
A doctor problem's key is its check name, such as `scheduler`, so a changing detail does not repeat it.
`state/alert-reported` lists the keys already handed to the parent chat. The scheduled run drops
keys that are no longer open, so a problem that comes back is reported again. It adds each new key
when it prints the problem, so two overlapping handoffs can never hide a problem from each other.
A `flock` on `state/alert-check.lock` makes two overlapping collections run one after the other.
The cost is that a handoff the parent chat never acts on is not repeated by this routine. The daily
routine still lists every open alert, so the owner hears about it within a day.

### Alert check scheduled run
```text
GrokBox-Main alert check. Repo at <REPO>. Collect new problems for the parent chat, in <LANGUAGE>.
This run only reads. Always return the handoff below, even when nothing is new.
Rules: never print secrets (secrets/*, restic password, tokens, auth URLs); never run status.sh --ack,
install.sh, backup.sh, restore.sh or --force; never edit config.env; never print or summarize
conversation content; no cookies, scraped tokens or internal APIs; do not change other bots' settings,
routines or memory. Write only the state files named in step 1.

1. Run exactly this and read its output:
cd <REPO> || exit 1
(
set -eE
trap 'echo "CHECK FAILED: a command failed at line $LINENO"' ERR
exec 9> state/alert-check.lock && flock -w 120 9 || { echo "CHECK FAILED: another alert check is still running"; exit 1; }
./doctor.sh > state/alert-doctor.out 2>&1 || true
grep -q '^Overall:' state/alert-doctor.out || { echo "CHECK FAILED: doctor.sh printed no Overall line:"; head -c 300 state/alert-doctor.out; exit 1; }
{ [ -s state/ALERT ] && awk '{print "alert " $0 "\t" $0}' state/ALERT
  awk -F: '/^PROBLEM/ {k=$1; sub(/^PROBLEM +/, "", k); print "doctor " k "\t" $0}' state/alert-doctor.out
} > state/alert-current.tsv
touch state/alert-reported
awk -F'\t' 'FILENAME==ARGV[1] {cur[$1]=1; next} $0 in cur' state/alert-current.tsv state/alert-reported > state/alert-reported.new
mv state/alert-reported.new state/alert-reported
awk -F'\t' 'FILENAME==ARGV[1] {seen[$0]=1; next} !($1 in seen)' state/alert-reported state/alert-current.tsv > state/alert-new.tsv
cut -f1 state/alert-new.tsv >> state/alert-reported
echo "--- new problems:"
cut -f2 state/alert-new.tsv
)
2. If any output line starts with "CHECK FAILED:", go to step 4. If nothing is printed after "--- new problems:", the first line of your result is exactly:
ALERT CHECK: nothing new
3. Otherwise the first line is exactly:
ALERT CHECK: NEW PROBLEMS, parent: tell the owner now
Then the printed problem lines, unchanged.
4. If step 1 fails or prints a "CHECK FAILED:" line, the first line is exactly:
ALERT CHECK: FAILED
Then the printed error text (at most 300 bytes). No logs, no message content, no secrets.
```

### Alert check parent chat
On each handoff, follow the line that matches the first line of the result:

- `ALERT CHECK: nothing new`. Do nothing. Do not message the owner.
- `ALERT CHECK: NEW PROBLEMS, parent: tell the owner now`. Send the owner one short message in
  `<LANGUAGE>` and plain words: what is wrong, the likely cause, and the next step. Use the cause and
  next-step list in step A3 above. Do not paste logs. The scheduled run has already recorded these
  problems, so you run no command.
- `ALERT CHECK: FAILED`. Tell the owner once per day that the alert check could not run, with the error text.

Do not acknowledge alerts, restart the scheduler, or change anything to fix a problem in this chat run.
The owner decides, and the daily routine's A1 step restarts a dead scheduler. After a fix, acknowledge with
`./status.sh --ack`, as described in the export loop section.
