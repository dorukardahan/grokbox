# REBUILD - what to do when the box moved, files are missing, or the box is brand new

What survives a box move: **files only** (`/workspace`, `/home/box`). Installed system packages, background
processes (the backup scheduler!) and anything under `/tmp` do NOT. Commands below run in the repo
directory (default `/workspace/grokbox`).

## 1. After any box move (files still there)
1. Wait ~15 minutes after boot: the platform may still be copying files back (the hydration guard and the minimum-uptime guard skip backups meanwhile).
2. `./install.sh --schedule` - verifies the binaries (re-downloads if missing), restarts the scheduler (hourly + quick snapshots,
   daily check, watchdog). It is idempotent. The daily watchdog routine from AGENTS.md step 8 does this automatically.
   If the `RESTIC_BACKUP_PASSWORD` box secret exists and `secrets/restic-pass` is missing, `install.sh` recreates the file.
3. `./status.sh` - check the last snapshot time and any `!!` ALERT banner (`./status.sh --ack` once handled).
4. If the stale-computer guard tripped (alert says STALE-COMPUTER GUARD; `state/GUARD_TRIPPED` blocks forget/prune): do not force. Compare
   `./restore.sh ls latest` with the live box. Only if the current state really is the truth, a human may run `./backup.sh --force "why"`.

## 2. Files missing, or the box rolled back to an old copy
1. Do **not** run `backup.sh --force` (it would record the damaged state as the newest snapshot).
2. `./restore.sh list` - pick the last good snapshot.
3. `./restore.sh <id> --missing-only /path/you/lost` - restores into `/workspace/restore-<date>-<id>/`,
   then offers to copy back ONLY files that are missing live. Existing files are never overwritten. Or just copy by hand from the restore directory.
4. `touch state/PAUSE` while you sort it out if hourly snapshots would otherwise run; `rm state/PAUSE` afterwards.

## 3. Brand-new empty box (disaster)
You need three things that live **outside** the box: the **restic password**, the **OAuth client JSON** (if you
used your own client) and **access to your Google account**.
1. `git clone <the Grok Box repo URL> /workspace/grokbox && cd /workspace/grokbox && cp config.env.example config.env` (use the same `GB_REMOTE`, `GB_FOLDER`, `BACKUP_HOST` as before).
2. Put the password back: set the box secret `RESTIC_BACKUP_PASSWORD` and run `./install.sh` (creates `secrets/restic-pass`).
3. Put the client JSON at `secrets/gdrive-oauth-client.json` and run `./auth-gdrive.sh` (a different client cannot see the old folder:
   `drive.file` scope; with rclone's default client use `--rclone-default-client`). Check: `./restore.sh list`.
4. Restore everything into a scratch dir and move it into place:
   `./restore.sh latest` -> `/workspace/restore-<date>-latest/` (contains `/workspace/...` and `/home/box/...`).
   Do not blanket-copy over the box. First `./restore.sh latest --missing-only` (it asks first): it only fills in files that do not exist yet.
   Then handle every file that exists in both places one by one: compare it with the restored copy, move the current file aside
   (e.g. `mv <path> <path>.old`), and only then copy the restored one into place. Consistent SQLite copies are under
   `staging/sqlite/<original path>` (the live `*.db` files of staged databases are intentionally not in the snapshot); restore each
   one this way (SQLite recovery, per database: stop whatever writes the DB; move the current DB and its
   `-wal`/`-shm` files aside; copy the consistent copy into place; run `sqlite3 <path> 'PRAGMA integrity_check'` (or
   `python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('pragma integrity_check').fetchone()[0])" <path>`), expect `ok`; then restart the app). Brain-export copies of stores outside the roots are under `staging/brain/stores/`.
5. With `BACKUP_SECRETS=1` (default) credential files, `~/.config`, CLI logins and rclone config come back with the files. The repo's own
   `secrets/restic-pass` is the one thing that does not (restore step 2). Then `./install.sh --schedule` and re-create the watchdog routine.
6. Tool inventory: `state/rebuild-kit/inventory.txt` (refreshed daily; inside the snapshot) lists installed CLIs, apt manual packages,
   npm/uv tools; `state/rebuild-kit/venvs/*.txt` are pip freezes of every venv. Venvs and model caches are in the backup by default; the
   freezes are the fallback when a restored venv does not run on a new image.

## 4. Re-login checklist (not in any backup)
- The restic password (password manager / box secret) and the OAuth client JSON (your copy outside the box).
- Box secrets (env vars) managed by the Grok Bot app: re-add them in the app.
- Connector/plugin OAuth grants and everything else server-side (README "Limits").
- Tokens that expired or were revoked: `./auth-gdrive.sh --reauth`, and any tool logins (`gh auth login`, etc.).
