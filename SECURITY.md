# Security policy

## Supported versions
There are no releases yet. Only the latest `main` is supported; fixes land there.

## Reporting a vulnerability
Report privately through GitHub: open the repository's **Security** tab and click
**Report a vulnerability**, or go straight to
<https://github.com/dorukardahan/grokbox/security/advisories/new>.

- **Do not open a public issue** for a vulnerability.
- There is no security e-mail address; use the private GitHub report.

Please include:
- what is affected (script, file, line or commit: `git rev-parse --short HEAD`);
- how to reproduce it, ideally with fake data in a temp directory (like the test suites do);
- what an attacker could do with it, and under which assumptions (local user on the box, someone with
  Drive access, someone who can change a download, ...).

Please **do not include** real secrets: no restic password, `rclone.conf`, OAuth tokens or client JSON,
`config.env`, webhook URLs, agent ids or conversation text. Redact them (`<token>`, `<id>`). If you
need to show that a secret leaks, use a fake one.

Response is best-effort: this is a community project maintained in spare time, without an SLA. You
will get an answer in the advisory thread when a maintainer has looked at it.

## Scope
In scope:
- the scripts and Python files in this repository (`*.sh`, `*.py`, `rebuild-kit/`);
- the download path in `install.sh`: pinned versions, checksum checks against both
  [checksums.txt](checksums.txt) and the upstream `SHA256SUMS`;
- how secrets are handled: the restic password file (never uploaded, never printed), `secrets/`
  permissions, `rclone.conf`, the OAuth client JSON, the one-time auth URL, `ALERT_HOOK` input;
- anything in the docs or routine prompts that tells a bot to do something unsafe.

Out of scope (please report upstream):
- bugs in restic (<https://github.com/restic/restic>), rclone (<https://github.com/rclone/rclone>),
  Google Drive or Google OAuth;
- the Grok Bot platform itself: its tools, servers, box isolation, retention of server-side data.

## Threat model in short
- Backups are encrypted by restic on the box before upload. Google can still see metadata (object
  names, sizes, timing, folder name). See [PRIVACY.md](PRIVACY.md).
- The **restic password** is the key to everything. Anyone with the password **and** access to the
  Drive folder can restore every snapshot. Keep it outside the box (password manager).
- Anyone who controls the box can read the live files, `secrets/` and the password file. Grok Box does
  not protect against a compromised box.
- **`BACKUP_SECRETS=1` is the default**: credential files on the box (for example `~/.ssh`, `~/.config/gh`,
  `~/.config/rclone`, `.env` files, browser cookie stores, and Grok Box's own `secrets/` except the
  restic password) are stored **inside the encrypted repository**. Set `BACKUP_SECRETS=0` in
  `config.env` to leave them out (list: [excludes-secrets.txt](excludes-secrets.txt)).
  `config.env` itself is **not** covered by that switch: it is always backed up, including any alert
  webhook or ntfy URL (and `ALERT_HOOK` command) in it. Treat those values like secrets that end up in the repository.
- With the optional server-side export, bot conversations are backed up too, including anything a
  user pasted into a chat (secrets as well).
- What a box backup cannot contain: README ["Limits"](README.md#limits-what-a-box-backup-cannot-contain).
