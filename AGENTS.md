# AGENTS.md - instructions for a Grok Bot (or any AI agent) setting up Grok Box

You were given the link to this repo. Goal: set up
encrypted, Time-Machine-style backups of this box (`/workspace` and `/home/box`) to the user's own
Google Drive, using restic + rclone. Everything runs without root and without a cron daemon.
Read this file fully before acting. Steps marked **[HUMAN]** cannot be done by you: ask the user,
give them exact instructions, and wait.

## Safety rules (always)
1. **Never print secrets**: not `secrets/restic-pass`, `secrets/rclone.conf`, `secrets/gdrive-oauth-client.json`,
   `$RESTIC_BACKUP_PASSWORD`, tokens, or the URL-with-state of an auth flow into places other than the
   user's own chat. Never `cat` those files. Never put them on a command line.
2. **Never commit or push** `config.env` or anything in `secrets/ state/ logs/ staging/ cache/ bin/`.
3. **Never bypass the stale-computer guard** (`backup.sh --force`) without the human's explicit OK, and only
   after comparing the box with the last good snapshot (`./restore.sh ls latest`, `./status.sh`).
4. **Never prune, forget, or delete** snapshots, repository data, or Drive folders without asking first.
   (The scheduled `check.sh` applies the configured retention by itself; that is expected.)
5. **Never overwrite live files on restore.** Restore into a restore directory, or use `--missing-only`.
6. Restore directories (`/workspace/restore-*`) are excluded from backups; do not delete them without asking the user.
7. Report to the user only what matters: decisions needed and problems. Do not dump logs.

## Setup, step by step

### 1. Clone and configure
```bash
git clone https://github.com/dorukardahan/grokbox /workspace/grokbox
cd /workspace/grokbox
cp config.env.example config.env     # optional edits: TZ, GB_FOLDER, BACKUP_ROOTS, retention, ...
```
Ask the user only if they want non-defaults (time zone for logs, which folders, `BACKUP_PROFILE=lean` for a
small 15 GB Drive, `PRUNE_USE_TRASH=0` to delete at once instead of the Drive trash on forget/prune).
Defaults: roots `/workspace /home/box`, hourly 24 / daily 30 / weekly 12 / monthly 12,
quick snapshots every 15 min kept 24 h, `TZ=UTC`, Drive folder `GrokBox/restic`.

**Always ask the owner these two, then write the answers into `config.env`:**
- **Time zone:** set `TZ` (the line `export TZ=UTC`) to the owner's zone, e.g. `Europe/Berlin`. All
  schedule times (hourly :17, daily check 04:40, weekly test restore) and log times use `TZ`.
- **Credentials in the backup:** `BACKUP_SECRETS=1` (default) puts credential files (tokens, `~/.ssh`,
  `~/.config` logins, CLI logins, rclone config, `.env` files...) inside the encrypted backup. Anyone with
  the restic password and access to the Drive folder can restore them. `BACKUP_SECRETS=0` leaves them
  out (then they must be re-created by hand after a disaster). Let the owner decide; do not pick for them.

### 2. Install the binaries
```bash
./install.sh
```
Downloads pinned `restic` and `rclone` into `bin/`, verifies SHA256 against `checksums.txt` and the upstream SHA256SUMS,
needs no root, supports linux amd64 and arm64.

### 3. [HUMAN] The restic password (the key to every backup)
Without this password the backups can never be restored, and it is the ONE secret that is never uploaded.
The human must keep it in **two** places:
- as a **box secret** named `RESTIC_BACKUP_PASSWORD` (so a rebuilt box can recreate `secrets/restic-pass`), and
- in their **password manager**.

Case A, the human supplies it: they add the box secret `RESTIC_BACKUP_PASSWORD` (a long random string)
in the Grok Bot app; then run `./install.sh` again. It creates `secrets/restic-pass` (chmod 600) from the env var and never prints it.

Case B, you generate it: `./install.sh --gen-password` writes a random password into `secrets/restic-pass`
without printing it. Tell the human: "Open `/workspace/grokbox/secrets/restic-pass` yourself, copy the
content into your password manager, and also store it as the box secret `RESTIC_BACKUP_PASSWORD`."
Do not print the file. (`--show-password` prints it; use only if the human explicitly asks.)
Do not continue to `--init` until the human confirms the password is saved in both places.

### 4. [HUMAN] Create a Google OAuth client (once, about 10 minutes)
Follow `docs/google-cloud-setup.md` with the user (project, Drive API, branding, audience External,
scope `drive.file`, **Publish to Production**, Desktop-app client, download the JSON). The JSON must end up on the box as
`/workspace/grokbox/secrets/gdrive-oauth-client.json` (the user can upload it to you; then `mv` it there
and `chmod 600` it; do not print it). The user must also **keep a copy of that JSON outside the box**.

Fallback if the user refuses: `./auth-gdrive.sh --rclone-default-client` (rclone's shared client: rate-limited,
may be retired, files only visible to that client, so migrating later needs `docs/migrate-client.md`). Warn the user plainly first.

### 5. [HUMAN] Authorise Google Drive (one click)
```bash
./auth-gdrive.sh          # own client (recommended)
```
The script waits up to 10 minutes, so run it in the background and read its output (or `state/auth-url.txt`, chmod 600).
It prints `http://127.0.0.1:53682/auth?state=...` (a one-time localhost URL, not a secret token, but do not keep or log it:
the script deletes `state/auth-url.txt` and its rclone output when it ends; if a token already exists it only verifies it). Open that URL **in the box's own browser** (rclone listens on the box), then
tell the human to sign in with their Google account and click **Allow** (an "unverified app" screen is expected for a
personal client: Advanced -> Go to app). When the script prints `OK: Drive connected`, continue.

### 6. Create the repository, dry run, first backup
```bash
./install.sh --init                 # creates the encrypted restic repo in Drive (one time)
./backup.sh --dry-run               # estimate, no upload
./backup.sh                         # first full snapshot (can take long; run it in the background and poll status.sh)
```
If the dry run or backup exits with 4, the stale guard tripped: see rule 3. On exit 7 Drive/auth is the problem.

### 7. Start the scheduler
```bash
./install.sh --schedule             # starts scheduler.sh (idempotent: no-op if running)
./status.sh                         # expect "Overall: OK" once the first snapshot exists
```
The scheduler is a background process: it **dies on a box move** (and with it all backups). That is what step 10 fixes.

### 8. First restore drill
A backup that was never restored is not tested. Once the first full backup from step 6 has finished
(`./status.sh` shows a last hourly snapshot):
```bash
./test-restore.sh                   # restores a sample into a private dir, verifies checksums, deletes it
./doctor.sh                         # the "test restore" line must be OK
./restore.sh list                   # the snapshots are there
```
Exit 75 means the backup lock is busy: retry in a few minutes. If the test restore fails, stop and tell
the owner (see `docs/runbooks.md`).

### 9. [HUMAN] Choose an alert channel
By default alerts only go to `state/ALERT` + `logs/alerts.log` and (after step 10) the bots' daily reports. Ask the owner where they want
alerts sent (e-mail, chat webhook, push service...) - never pick one for them. Then set `ALERT_HOOK` in
`config.env`: a command that receives the alert text on stdin. Examples and details:
`docs/health-and-alerts.md`. If the owner wants no extra channel, leave it empty.

### 10. Create the two Grok Box bots: GrokBox-Main and GrokBox-Assist (do this yourself)
A box backup alone misses what lives only on the Grok Bot servers: every bot's full conversation history
and the bots' memory. They can only be read with the Grok Bot tools `ReadTranscript` and `RecallMemory`.
These are **bot tools**: no script, cron or `scheduler.sh` can call them, and you must never use cookies,
scraped tokens or internal APIs instead. So all ongoing backup work is done by **two dedicated bots**, each
with its own daily routine. Scheduled runs check health and export memory, but lack ReadTranscript
and cannot talk to the owner. Every run explicitly hands transcript paging to its normal parent chat.
**You (the primary bot) keep no backup routine.** Delete or disable any older
Grok Box / watchdog routine of yours once both bots are running. Read [docs/bots.md](docs/bots.md) first.

- **GrokBox-Main** does all backup work. Box side: `install.sh --schedule`, `status.sh`, alerts, Drive
  re-consent. Server side: it exports every bot's conversation and the memory.
- **GrokBox-Assist** exports Main's own conversation and your main chat. A bot cannot export the
  conversation it is running in. Assist also checks that Main's run happened, and covers for Main if it
  missed one. Each bot exports the other, so both see each other's work.

Steps:
1. **Create both bots** with your `CreateAgent` tool: names `GrokBox-Main` and `GrokBox-Assist`. Use the
   personas in [docs/bots.md](docs/bots.md), with `<REPO>`, `<LANGUAGE>`, `<MAIN_ID>` and `<PRIMARY_ID>`
   filled in. `<PRIMARY_ID>` is your own agent id; create Main first so that you know `<MAIN_ID>`. Note both
   new ids. If bots with these names already exist, reuse them instead of creating duplicates.
2. **Pick staggered times** in the user's time zone, for example Main 05:15 and Assist 09:00. Keep them
   away from `check.sh` (04:40 by default) and at least 2 hours apart.
3. **Brief each bot** with your `SendToAgent` tool, using the setup briefs in [docs/bots.md](docs/bots.md),
   filled in. Each bot then:
   - reads its template ([docs/routine-main.md](docs/routine-main.md) or [docs/routine-assist.md](docs/routine-assist.md));
   - **creates its own daily routine with its `UpdateRoutine` tool**;
   - **runs the first full export right away in its normal chat, not in the scheduled routine**.
     Main exports all bots except itself; Assist exports Main and your main chat.
   They reply with a short status. Do not paste conversation content anywhere.
4. **Your own memory:** the two bots cannot read your private memory. Keep durable facts in the user's
   shared memory, and export your private memory once now. Run a few `RecallMemory` queries with
   `write_to_file: true` (if your RecallMemory has no such option, paste each inline result verbatim into
   `/workspace/agent-tools/primary-mem-<n>.txt` with a quoted heredoc, `<<'GROKBOX_MEM_END_7Q2'`; see [docs/server-export.md](docs/server-export.md)), then:
   `python3 server-export-merge.py memory --remove --out primary-bot-private --label "primary bot" <files>`.
5. **Check** `staging/server-export/INDEX.md`. Every row should be `complete`, `empty` or `not readable`,
   and Main, Assist and your own id must be present. Then run `./backup.sh` (or wait for the next hourly)
   so the export is in a snapshot.

Both parent chats report to the user **only on problems**: `Overall` not OK, Drive re-consent needed, stale
guard, export gaps, or a missed partner run. Details: [docs/server-export.md](docs/server-export.md).

### 11. Fill the expected-bot roster
Once the first export is complete, set `EXPECTED_BOTS` in `config.env` to the bots that must be in every
server-side export (names or agent ids), at least `("GrokBox-Main" "GrokBox-Assist")` plus the owner's
important bots. Real bot names go **only** into the local `config.env`, never into the repo, an issue or a
commit. Then run:
```bash
./expected-bots.sh                  # expect "all N expected bots present and complete ..."
```
Bots deleted later are recognised through `DELETED_BOTS_FILE`; list retired ones in `RETIRED_BOTS`.

### 12. Finish
Tell the user, briefly: what is backed up, the schedule, where the repo is (`Drive: GrokBox/restic`), and remind them
about the three things they must keep outside the box: the restic password, the OAuth client JSON, and their Google
account access. Say that GrokBox-Main and GrokBox-Assist now run the backups every day (box health + every bot's server-side
conversation history and a sample of the shared memory: RecallMemory answers about 10 generic queries,
not a full dump), and that they only report problems.
Mention what still cannot be backed up (README "Limits": bots' private memory other than the two Grok Box bots', Pages, connector grants, app-managed secrets).

## Day-to-day commands
| need | command |
|---|---|
| health | `./status.sh --local` (no network), `./status.sh` (full) |
| server export status | `python3 server-export-merge.py next` (`{}` = complete), `staging/server-export/INDEX.md` |
| acknowledge handled alerts | `./status.sh --ack` |
| list / browse snapshots | `./restore.sh list`, `./restore.sh ls latest [path]` |
| restore into a new dir | `./restore.sh <id\|latest> [path...]` -> `/workspace/restore-<date>-<id>/` |
| restore only what is missing | `./restore.sh <id> --missing-only [path...]` (asks first; `--yes` only after the human agreed) |
| pause / resume backups | `touch state/PAUSE` / `rm state/PAUSE` |
| after a box move | `./install.sh --schedule`, then `./status.sh`; see `REBUILD.md` |
| repair / undo prune / wrong host | see `docs/runbooks.md` (never prune while `check` fails; ask human before rewriting/dropping snapshots) |

If something fails, read `REBUILD.md`, `docs/runbooks.md`, `README.md`, and `logs/backup-YYYY-MM.log` (never the secrets).
