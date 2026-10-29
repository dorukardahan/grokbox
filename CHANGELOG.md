# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no tagged releases yet; `main`
is the only supported version.

## [Unreleased]

### Added
- `server-export-merge.py dedupe [--dry-run] [ID...]` cleans adjacent repeated transcript blocks
  for ids with failed-overlap warnings, ignoring volatile memory-context lines when comparing,
  preserving originals and updating export counts and warnings.
- Community files: `CONTRIBUTING.md`, `SECURITY.md` (private reporting through GitHub security
  advisories), `CODE_OF_CONDUCT.md`, this changelog.
- GitHub issue forms (bug report with redaction checklist, feature request), issue template config
  with a private vulnerability link, and a pull request template.
- `ci/github-actions-ci.yml.example` is now the full CI workflow (shellcheck, then each test suite in its
  own step, a 30-minute job timeout, cancellation of superseded runs). Copy it to
  `.github/workflows/ci.yml` to enable it.
- `docs/platform-contract.md`: what Grok Box assumes from the Grok Bot platform (ReadTranscript and
  RecallMemory result formats, deleted-bots file shapes, agents directory layout, bot tools, unknowns)
  and how to run without a Grok Bot.
- README: "Status & disclaimer" box, "Requirements & platform assumptions" section, voice
  conversation notes, a prominent warning that `BACKUP_SECRETS=1` (default) puts credential files in
  the encrypted backup.
- AGENTS.md onboarding: ask the owner for `TZ` and the `BACKUP_SECRETS` decision (step 1), first
  restore drill (step 8), alert channel via `ALERT_HOOK` (step 9), `EXPECTED_BOTS` roster (step 11).
- PRIVACY.md: conversations and voice content in the server-side export, and how to stop or remove it.

### Changed
- Docs: GrokBox-Assist's routine now runs twice a day (one routine, two times, e.g. `0 9,21 * * *`)
  instead of once. Main's export row is refreshed only through Assist's handoff, so this gives about
  14 h of slack for one delayed handoff, while a fully missed day still alerts at the unchanged
  26 h `EXPORT_MISSED_HOURS` limit. No script changes.
- AGENTS.md steps renumbered: the bot setup is now step 10 and "Finish" step 12 (step 3, the restic
  password, keeps its number because `status.sh` and `doctor.sh` refer to it). References in
  `REBUILD.md` and `docs/server-export.md` updated.
- `docs/routine-main.md`: the parent chat's last step is now "Final check (after B3)" instead of
  "B7", and a "Step names" note explains that B1–B3 run only in the parent chat and B4–B6 only in the
  scheduled prompt. The handoff line is unchanged. `tests/ci-install.sh` checks the numbering.

### Fixed
- A backup no longer trips over its own restic lock: when the backup's restic process has exited but its lock is still
  in the repository (seen after a VM pause during the backup's start), snapshot promotion now lists locks first and,
  only if one is there, runs the stale-only unlock quietly before promoting. Promotion succeeds on the first try with no
  unlock alert; the cleanup is logged and uses the shared single-unlock budget.
- A Drive call that goes silent (for example after a VM pause) can no longer hang a backup step for hours: rclone gets
  transport timeouts (`RCLONE_NET_ARGS`), `restic tag/unlock/snapshots/cat` are limited to `RESTIC_TIMEOUT_META` (10m) and
  `forget` to `RESTIC_TIMEOUT_FORGET` (30m), a timeout raises an alert, and a timed-out snapshot promotion is retried once
  after the usual single plain unlock.
- Incremental transcript overlap matching ignores volatile user `<memory_context>` lines on both
  sides after exact matching fails, requiring an ordinary matching line and preserving new context.
- Docs no longer say the shared memory is "backed up" without a caveat: the memory export is a
  sample from a fixed set of RecallMemory queries, not a complete dump.
- REBUILD.md no longer refers to a "daily watchdog routine"; it points to the GrokBox-Main and
  GrokBox-Assist daily routines, which run `install.sh --schedule`.
- README Schedule section says explicitly that times are in `TZ` (UTC unless changed).
- PRIVACY.md has a full "Last updated" date.

## History (pre-release)
Merged pull requests before the first release, newest first:

- **#4** Stale-lock handling in snapshot promotion: snapshot promotion no longer fails on stale locks.
- **#3** Transcript export handed to the bots' parent chats (scheduled runs cannot read transcripts),
  plus a daily-export-missed check (`export-freshness.sh`).
- **#2** Deleted-bots roster: deleted and retired bots count as OK in the expected-bot roster, are
  labelled "(deleted)" in `INDEX.md`, and a same-name replacement that was never exported raises a
  warning.
- **#1** Health check (`doctor.sh`), weekly test restore, alerts, expected-bot roster, Drive backup
  report, and review fixes.

The earliest commits built the base: encrypted restic + rclone backups to Google Drive, the
server-side export (`server-export-merge.py`) and the two backup bots (GrokBox-Main and
GrokBox-Assist). See `git log` for details.
