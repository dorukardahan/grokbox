# Migrating the backup to a different Google OAuth client

Typical case: you started with `./auth-gdrive.sh --rclone-default-client` (rclone's shared client) and now
have your own client (docs/google-cloud-setup.md). Because the scope is `drive.file`, **a remote only sees files
created by its own client**: the new client cannot see the old folder. So the plan is a new remote and folder, plus
`restic copy` of the whole snapshot history, so nothing is lost. Placeholders: OLD = old remote/folder, NEW = new.

## 0. Prerequisites
- Your own OAuth client JSON saved as `secrets/gdrive-oauth-client.json`; app published to Production (a copy of the JSON stored outside the box).
- Work from the repo directory. Pause backups and wait until idle:
  ```bash
  touch state/PAUSE
  ./status.sh --local        # wait until there is no "Running now:" line
  ```

## 1. Authorise a second remote with the new client (keeps the old one untouched)
```bash
GB_REMOTE=gdrive2 GB_FOLDER=GrokBox-v2/restic ./auth-gdrive.sh
```
`GB_REMOTE` / `GB_FOLDER` from the environment override the values in `config.env` (they are only defaults there). The result is a `[gdrive2]` section in `secrets/rclone.conf`; `./auth-gdrive.sh` keeps other sections.

## 2. Create the new repository with the same password and chunker parameters, copy the history
```bash
source ./lib.sh; set +e; trap - ERR
OLD="rclone:gdrive:GrokBox/restic"; NEW="rclone:gdrive2:GrokBox-v2/restic"
R -r "$NEW" init --from-repo "$OLD" --from-password-file "$RESTIC_PASSWORD_FILE" --copy-chunker-params
R -r "$NEW" copy --from-repo "$OLD" --from-password-file "$RESTIC_PASSWORD_FILE"   # may take hours; resumable
R -r "$NEW" snapshots --no-lock | tail -3
```
`--copy-chunker-params` keeps deduplication identical, so the next backup adds only changes. If `copy` is interrupted run it again.
(If history is not needed: skip `copy`; the first backup re-uploads everything.)

## 3. Switch
In `config.env` set `GB_REMOTE=gdrive2` and `GB_FOLDER=GrokBox-v2/restic`, then:
```bash
rm -f state/PAUSE          # the scheduler re-execs itself on the config change
./backup.sh && ./status.sh && ./test-restore.sh
```
Rollback is possible any time before step 4: set the old values again.

## 4. Clean up (only after at least 30 days of good backups and a passing test restore)
Delete the old folder in the Drive web UI and the old `[gdrive]` section from `secrets/rclone.conf`.
Update your disaster notes: restoring now needs the new client JSON (`./auth-gdrive.sh`).
