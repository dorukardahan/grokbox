## What and why
<!-- What does this change, and why is it needed? -->

## How it was tested
<!-- Which suites did you run? e.g. bash tests/smoke.sh, tests/ci-install.sh, tests/health.sh, tests/locks.sh, tests/maintenance.sh -->

## Checklist
- [ ] Tests added or updated for new behaviour (behaviour, not implementation)
- [ ] `shellcheck --severity=warning ./*.sh rebuild-kit/*.sh tests/*.sh` is clean
- [ ] Docs and `CHANGELOG.md` ("Unreleased") updated
- [ ] No real data in fixtures, logs or screenshots (ids, e-mails, bot names, host names, conversation text)
- [ ] An existing `config.env` still works (new settings have a default in `lib.sh` and an entry in `config.env.example`)
- [ ] No secrets (tokens, passwords, `rclone.conf`, `config.env`, `secrets/`)

## Related issue
<!-- Fixes #123 -->
