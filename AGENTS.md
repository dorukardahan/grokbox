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
small 15 GB Drive). Defaults: roots `/workspace /home/box`, hourly 24 / daily 30 / weekly 12 / monthly 12,
quick snapshots every 15 min kept 24 h, `TZ=UTC`, Drive folder `GrokBox/restic`.

### 2. Install the binaries
```bash
./install.sh
```
Downloads pinned `restic` and `rclone` into `bin/`, verifies SHA256 against the upstream SHA256SUMS,
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
The scheduler is a background process: it **dies on a box move** (and with it all backups). That is what step 8 fixes.

### 8. Daily watchdog routine (do this; it is what keeps backups alive)
Create a **daily** Grok Bot routine/automation (any hour) with this task:
> Run `cd /workspace/grokbox && ./install.sh --schedule; sched_rc=$?; ./status.sh --local; echo "schedule_rc=$sched_rc"`.
> Always run `status.sh --local`, even if `install.sh --schedule` failed. Stay silent only if `schedule_rc=0`
> AND the last line of `status.sh` was `Overall: OK`. Otherwise report the `!!` lines (and the failed
> `install.sh --schedule`) to the user. Never use `--force`, never prune or delete anything, never print secrets.

`install.sh --schedule` is idempotent: it restarts the scheduler after a box move and does nothing otherwise. The
routine reports to the user **only when Overall != OK**.

### 9. Finish
Tell the user, briefly: what is backed up, the schedule, where the repo is (`Drive: GrokBox/restic`), and remind them
about the three things they must keep outside the box: the restic password, the OAuth client JSON, and their Google
account access. Mention what cannot be backed up (README "Limits": server-side data, connector grants, app-managed secrets).

## Day-to-day commands
| need | command |
|---|---|
| health | `./status.sh --local` (no network), `./status.sh` (full) |
| acknowledge handled alerts | `./status.sh --ack` |
| list / browse snapshots | `./restore.sh list`, `./restore.sh ls latest [path]` |
| restore into a new dir | `./restore.sh <id\|latest> [path...]` -> `/workspace/restore-<date>-<id>/` |
| restore only what is missing | `./restore.sh <id> --missing-only [path...]` (asks first; `--yes` only after the human agreed) |
| pause / resume backups | `touch state/PAUSE` / `rm state/PAUSE` |
| after a box move | `./install.sh --schedule`, then `./status.sh`; see `REBUILD.md` |

If something fails, read `REBUILD.md`, `README.md`, and `logs/backup-YYYY-MM.log` (never the secrets).
