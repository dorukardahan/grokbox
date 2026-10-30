# Privacy Policy - Grok Box

Applies to the open-source software at https://github.com/dorukardahan/grokbox ("Grok Box") and to the
Google OAuth client you create to run it. Last updated: 2026-10-30.

- **Who runs it.** Grok Box runs only on the machine (the "box") of the person who installs it. There is no Grok Box
  server, account or hosted service, and the authors operate no backend.
- **Google access requested.** Only the `https://www.googleapis.com/auth/drive.file` scope: per-file access to files the
  app creates, or files you explicitly open with or share to the app. It does not request your email, contacts,
  calendar or other Google data, and cannot browse the rest of your Drive.
- **Encryption.** Backup contents are encrypted on your machine by restic before upload. Google can still see operational
  metadata: object names (random hashes), sizes, timing and the folder name.
- **Network.** Grok Box talks only to Google OAuth and Drive endpoints and, at install time, to GitHub and rclone.org to
  download the restic and rclone binaries. No telemetry, analytics or reports go to the authors or any third party.
  The one exception is opt-in: if you set `ALERT_NTFY_URL`, `ALERT_WEBHOOK_URL` or `ALERT_HOOK` in `config.env`, the alert text
  (a short status message such as "no successful hourly backup for 3 h", not backup contents) is sent to that address or command, which you chose.
- **Credentials.** OAuth tokens, the client secret and the restic password file are stored on your box with owner-only
  permissions. With `BACKUP_SECRETS=1` (default) credential files other than the restic password are also inside the
  encrypted backup; set `BACKUP_SECRETS=0` to leave them out.
- **Conversations and voice content.** If you use the optional server-side export (the GrokBox-Main and
  GrokBox-Assist bots), your bots' conversation transcripts, including the text of voice calls as it
  appears in those transcripts, and a sample of the shared memory are written to the box under
  `staging/server-export/` and from there into the encrypted backup. Anything you or anyone else pasted
  into a chat, secrets included, is therefore in the exports and in the backups. There is no redaction.
  To turn it off, do not set up the two bots (or delete their routines). To remove the data, delete
  `staging/server-export/`; snapshots that were taken earlier keep their copies until those snapshots are
  forgotten and pruned (by the normal retention, or by hand with `restic forget` + `restic prune`, see the
  restic documentation), and with `PRUNE_USE_TRASH=1` the pruned files stay in the Drive trash for about
  30 days. Independently of the export, any conversation data the platform keeps as files on the box
  (under the backup roots) is backed up like every other file.
- **Retention and deletion.** Retention automatically deletes old snapshots according to your config (`KEEP`,
  `KEEP_QUICK`). By default those deleted files go to the Drive trash, where they stay recoverable for about 30 days and
  count against your Drive quota until Google empties the trash; set `PRUNE_USE_TRASH=0` to delete them at once. Remaining data stays in your Drive until you delete the backup folder
  (default `GrokBox/restic`).
- **Shared rclone client.** If you choose the fallback `--rclone-default-client`, sign-in uses rclone's own OAuth client,
  which is governed by rclone's and Google's terms, not by this app.
- **Revoking access.** Remove access at https://myaccount.google.com/permissions (optionally delete your OAuth client /
  Google Cloud project), then delete the backup folder in Drive if you want the data gone.
- **Children.** Not directed at children.
- **Changes and contact.** Changes are made in this file (see git history). Questions: open an issue at
  https://github.com/dorukardahan/grokbox/issues .
