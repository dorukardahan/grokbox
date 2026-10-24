# Privacy Policy - Grok Box

Applies to the open-source software at https://github.com/dorukardahan/grokbox ("Grok Box") and to the
Google OAuth client you create to run it. Last updated: 2026.

- **Who runs it.** Grok Box runs only on the machine (the "box") of the person who installs it. There is no Grok Box
  server, account or hosted service, and the authors operate no backend.
- **Google access requested.** Only the `https://www.googleapis.com/auth/drive.file` scope: per-file access to files the
  app creates, or files you explicitly open with or share to the app. It does not request your email, contacts,
  calendar or other Google data, and cannot browse the rest of your Drive.
- **Encryption.** Backup contents are encrypted on your machine by restic before upload. Google can still see operational
  metadata: object names (random hashes), sizes, timing and the folder name.
- **Network.** Grok Box talks only to Google OAuth and Drive endpoints and, at install time, to GitHub and rclone.org to
  download the restic and rclone binaries. No telemetry, analytics or reports go to the authors or any third party.
- **Credentials.** OAuth tokens, the client secret and the restic password file are stored on your box with owner-only
  permissions. With `BACKUP_SECRETS=1` (default) credential files other than the restic password are also inside the
  encrypted backup; set `BACKUP_SECRETS=0` to leave them out.
- **Retention and deletion.** Retention automatically deletes old snapshots according to your config (`KEEP`,
  `KEEP_QUICK`); deletion bypasses the Drive trash. Remaining data stays in your Drive until you delete the backup folder
  (default `GrokBox/restic`).
- **Shared rclone client.** If you choose the fallback `--rclone-default-client`, sign-in uses rclone's own OAuth client,
  which is governed by rclone's and Google's terms, not by this app.
- **Revoking access.** Remove access at https://myaccount.google.com/permissions (optionally delete your OAuth client /
  Google Cloud project), then delete the backup folder in Drive if you want the data gone.
- **Children.** Not directed at children.
- **Changes and contact.** Changes are made in this file (see git history). Questions: open an issue at
  https://github.com/dorukardahan/grokbox/issues .
