# Contributing to Grok Box

Thanks for helping. Grok Box is a small **community project**, maintained on a best-effort basis in
spare time. There is no SLA: issues and pull requests may take a while to get an answer.

`AGENTS.md` is written for bots that set up Grok Box on a box. It is not a contributor guide; this
file is.

## Reporting a problem
1. **Search first**: open and closed [issues](https://github.com/dorukardahan/grokbox/issues) may
   already cover it. Also read [docs/runbooks.md](docs/runbooks.md) and [REBUILD.md](REBUILD.md).
2. **Security problems never go into a public issue.** See [SECURITY.md](SECURITY.md).
3. Open an issue with one of the templates (bug report or feature request).
4. For a bug, include the output of `./doctor.sh --json` and the relevant log lines
   (`logs/backup-YYYY-MM.log`, `logs/alerts.log`), **redacted** (see below).

### How to redact
Before you paste anything, replace these with placeholders such as `<id>`, `<host>`, `<folder>`:

| remove | examples of where it shows up |
|---|---|
| agent / bot ids, snapshot ids, UUIDs | `INDEX.md`, `expected-bots.sh` output, log lines |
| host names | `doctor.sh --json` (`"host"`), `BACKUP_HOST`, restic output |
| Drive folder names and remote names, if they say something about you | `GB_FOLDER`, `GB_REMOTE`, report lines |
| e-mail addresses | the Google account, `ALERT_HOOK` commands |
| bot names (other than `GrokBox-Main` / `GrokBox-Assist`) | `EXPECTED_BOTS`, roster lines, `INDEX.md` |
| conversation text and memory facts | anything from `staging/server-export/` |
| file paths that contain names | your own project folders |

**Never paste** `config.env`, anything from `secrets/`, `rclone.conf`, the restic password, OAuth
client JSON, tokens, auth URLs or webhook URLs. If you pasted one by mistake: delete the comment,
and rotate the secret (new token, new password, new webhook) - assume it is leaked.

## Development setup
You need: `bash` (4 or newer), `python3`, `shellcheck`, `sqlite3`, `curl`, plus the usual coreutils
(`timeout`, `flock`, `sha256sum`). No root, no Google account, no Drive.

```bash
git clone https://github.com/dorukardahan/grokbox
cd grokbox
bash tests/smoke.sh      # the first run downloads the pinned restic + rclone into bin/ (SHA256-checked)
```
You do **not** need `cp config.env.example config.env` for the tests: every suite writes its own
config into a temp directory under `/tmp`, uses a local restic repository and fake binaries where
needed, and never touches `/workspace`, `/home/box` or a real Drive.

### Test suites
Run `tests/smoke.sh` first: `health.sh` and `maintenance.sh` need the `bin/restic` it downloads.
Durations depend on the machine and are not measured here; the first `smoke.sh` run is slower
because it downloads the binaries.

| suite | what it covers |
|---|---|
| `bash tests/smoke.sh` | end-to-end flow against a local restic repo: install, init, backups, restore, guards, check, scheduler, server-export failure cases |
| `bash tests/ci-install.sh` | CI workflow file, pinned checksums and `install.sh` download verification (fake `curl`), runbook commands, doc links and the routine handoff line |
| `bash tests/health.sh` | `doctor.sh`, weekly test restore, alert dedupe + `ALERT_HOOK`, expected-bot roster, Drive report (fake rclone) |
| `bash tests/locks.sh` | lock and snapshot-promotion regressions with a fake restic and synthetic credentials |
| `bash tests/maintenance.sh` | `PRUNE_USE_TRASH`, `server-export-merge.py` exit codes and crash-safe writes, `restore.sh`, log retention, quota check |

Lint (CI runs the same):
```bash
shellcheck --severity=warning ./*.sh rebuild-kit/*.sh tests/*.sh
```
Once enabled, the CI workflow ([ci/github-actions-ci.yml.example](ci/github-actions-ci.yml.example), copied to `.github/workflows/ci.yml`) runs shellcheck and every suite on each push
to `main` and on every pull request.

`KEEP_TMP=1 bash tests/<suite>.sh` keeps the temp directory for debugging (smoke, health,
maintenance and ci-install support it).

## Privacy rules for fixtures, logs and screenshots
This is a public repo. Test fixtures, examples, docs, logs and screenshots contain **fake data only**:
- bots: `bot-a`, `bot-b`, `GrokBox-Main`, `GrokBox-Assist`; ids like `abcdef12`;
- accounts and URLs: `you@example.com`, `example.com`;
- secrets: obviously fake strings (`synthetic test fixture`), never a real-looking token.

Before you push, scan your diff. A privacy scan should look for:
- e-mail addresses (anything with `@` that is not `example.com`, or a GitHub handle in a URL);
- UUIDs and long hex/base64 strings (agent ids, tokens, keys);
- real person names, real bot names, real host names;
- personal paths (anything beyond the documented `/workspace`, `/home/box/agent-data`, `/cursor/stores`);
- conversation text or memory facts copied from `staging/server-export/`;
- `token =`, `client_secret`, `refresh_token`, `Authorization:`, webhook URLs.

```bash
git diff main... | grep -nEi '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|[0-9a-f]{8}-[0-9a-f]{4}-|token|secret|password'
```
Every hit needs a look; most will be harmless variable names.

## Branches and pull requests
- Fork the repo (or use a branch if you have write access). **Never push to `main`.**
- One topic per pull request. Small PRs get reviewed sooner.
- New behaviour needs a test. Test the behaviour (exit codes, files written, printed status lines),
  not the implementation details.
- Update the docs that describe the behaviour, and add a line under "Unreleased" in
  [CHANGELOG.md](CHANGELOG.md).
- **Keep old `config.env` files working.** Users copy `config.env.example` once and never update it.
  Every new setting needs a default in `lib.sh` (the "defaults for settings added after a config.env
  was written" block) and an entry with a comment in `config.env.example`.
- Fill in the pull request template; link the issue it fixes.

**Bigger changes** (new features, new dependencies, changes to the routine prompts, the restic
repository layout or the handoff text): open an issue first and describe the plan, so nobody spends
time on something that will not be merged.

## Coding style
- Bash scripts start with `set -Eeuo pipefail` (or source `lib.sh`, which sets it) and are
  shellcheck-clean at `--severity=warning`.
- Comments explain **why**, not what. Match the density and tone of the code around you.
- Python is standard library only, `python3` without extra packages.
- No secret is ever printed, logged or put on a command line.
- Prefer safe defaults: never overwrite live files, never delete repository data without a latch or
  a human.

## Commits
- Subject in the imperative mood, at most 72 characters ("Fix stale-lock failures in snapshot promotion").
- The body says **why** the change is needed, and anything a reviewer should know.
- No secrets, ids or personal data in commit messages either.

## What reviewers look for
- Data safety first: can this lose backups, overwrite live files, or delete repository data?
- Secrets: nothing printed, logged, committed or uploaded that should not be.
- Old configs still work; defaults are safe.
- Tests cover the new behaviour and all suites pass; shellcheck is clean.
- Docs, `config.env.example` and `CHANGELOG.md` match the code.
- Privacy: fake data only.

## License
Grok Box is MIT licensed ([LICENSE](LICENSE)). By contributing you agree that your contribution is
released under the same license.

Please also follow the [Code of Conduct](CODE_OF_CONDUCT.md).
