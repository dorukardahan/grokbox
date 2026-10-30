#!/usr/bin/env bash
# Offline tests for GitHub Actions CI workflow, pinned archive checksums in install.sh,
# operational runbooks (repair, untrash, wrong-host rewrite), and README/AGENTS documentation links.
# shellcheck disable=SC2016
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grokbox-ci-install.XXXXXX")"
[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] || { echo "refusing: temp dir $TMP is not under /tmp"; exit 1; }
cleanup() {
  [[ -n "${KEEP_TMP:-}" ]] && { echo "kept $TMP"; return; }
  chmod -R u+rwX "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RCLONE_CONFIG

PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N+1)); echo "  ok   - $*"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
run_ok() { local d="$1"; shift; if "$@" >"$TMP/last.out" 2>&1; then pass "$d"; else fail "$d"; sed 's/^/       | /' "$TMP/last.out" | tail -15; fi; }
not() { ! "$@"; }
step() { echo; echo "== $*"; }

# Read PINNED_RESTIC and PINNED_RCLONE from config.env.example
PINNED_RESTIC=$(awk -F= '/^PINNED_RESTIC=/{print $2}' "$REPO_DIR/config.env.example")
PINNED_RCLONE=$(awk -F= '/^PINNED_RCLONE=/{print $2}' "$REPO_DIR/config.env.example")

step "1. GitHub Actions CI workflow (ci/github-actions-ci.yml.example)"
CI_YML="$REPO_DIR/ci/github-actions-ci.yml.example"
check "ci.yml exists" test -s "$CI_YML"
check "ci.yml triggers on push" grep -qE 'push:' "$CI_YML"
check "ci.yml limits push to main branch" grep -qE 'branches:[[:space:]]*\[main\]' "$CI_YML"
check "ci.yml triggers on pull_request" grep -qE 'pull_request:' "$CI_YML"
check "ci.yml sets minimal permissions (contents: read)" grep -qE 'contents:[[:space:]]*read' "$CI_YML"
check "ci.yml pins actions/checkout to a commit SHA (# v4)" grep -qE 'actions/checkout@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v4' "$CI_YML"
check "ci.yml runs shellcheck" grep -q 'shellcheck' "$CI_YML"
check "ci.yml runs tests/smoke.sh" grep -q 'bash tests/smoke.sh' "$CI_YML"
check "ci.yml loops over other tests/*.sh files" grep -q 'for t in tests/\*\.sh' "$CI_YML"
for t in ci-install health locks maintenance; do
  check "ci.yml runs tests/$t.sh in its own step" grep -q "run: bash tests/$t\.sh" "$CI_YML"
done
check "ci.yml sets a job timeout" grep -qE 'timeout-minutes:[[:space:]]*[0-9]+' "$CI_YML"
check "ci.yml cancels superseded runs per ref" grep -qE 'cancel-in-progress:[[:space:]]*true' "$CI_YML"

step "2. Pinned checksums (checksums.txt + install.sh verification)"
SUMS="$REPO_DIR/checksums.txt"
check "checksums.txt exists" test -s "$SUMS"
for arch in amd64 arm64; do
  rb="restic_${PINNED_RESTIC}_linux_${arch}.bz2"
  rz="rclone-v${PINNED_RCLONE}-linux-${arch}.zip"
  check "checksums.txt has pinned SHA256 for $rb" grep -qE "^[0-9a-f]{64}  $rb\$" "$SUMS"
  check "checksums.txt has pinned SHA256 for $rz" grep -qE "^[0-9a-f]{64}  $rz\$" "$SUMS"
done

# Set up isolated offline config and fake curl for install.sh tests
mkdir -p "$TMP/state" "$TMP/logs" "$TMP/staging" "$TMP/cache" "$TMP/secrets" "$TMP/fakebin"
cat > "$TMP/config.env" <<CFG
GB_BIN="$REPO_DIR/bin"
GB_SECRETS="$TMP/secrets"
GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export AGENTS_DIR="$TMP/agents"
export RESTIC_REPOSITORY="$TMP/repo"
CFG
export GB_CONFIG="$TMP/config.env"
export RESTIC_CACHE_DIR="$TMP/cache"   # direct rs calls must also stay inside the fixture
export RESTIC_BACKUP_PASSWORD="ci-install-test-password-$$"

# Missing entry in checksums.txt when bumping PINNED_RESTIC must fail loudly with hint
{ cat "$TMP/config.env"; echo "PINNED_RESTIC=9.99.9"; } > "$TMP/config-bump.env"
rc=0; GB_CONFIG="$TMP/config-bump.env" "$REPO_DIR/install.sh" >"$TMP/bump.out" 2>&1 || rc=$?
check "install.sh fails when bumped version is missing from checksums.txt" test "$rc" != 0
check "install.sh error mentions checksums.txt update hint" grep -q 'checksums.txt' "$TMP/bump.out"

# Offline download verification test using synthetic archives and a local fake curl
SRV="$TMP/srv"; mkdir -p "$SRV"
case "$(uname -m)" in x86_64|amd64) T_ARCH=amd64;; aarch64|arm64) T_ARCH=arm64;; *) T_ARCH=amd64;; esac
RB_NAME="restic_${PINNED_RESTIC}_linux_${T_ARCH}.bz2"
RZ_NAME="rclone-v${PINNED_RCLONE}-linux-${T_ARCH}.zip"

python3 - "$SRV" "$RB_NAME" "$RZ_NAME" "$PINNED_RESTIC" "$PINNED_RCLONE" "$T_ARCH" <<'PY'
import bz2, os, stat, sys, zipfile
srv, rb_name, rz_name, vr, vc, arch = sys.argv[1:7]
restic_sh = f"#!/usr/bin/env bash\necho 'restic {vr} compiled with go'\n".encode()
rclone_sh = f"#!/usr/bin/env bash\necho 'rclone v{vc}'\n".encode()
with bz2.open(os.path.join(srv, rb_name), "wb") as f:
    f.write(restic_sh)
with zipfile.ZipFile(os.path.join(srv, rz_name), "w") as zf:
    zf.writestr(f"rclone-v{vc}-linux-{arch}/rclone", rclone_sh)
PY

RB_SHA=$(sha256sum "$SRV/$RB_NAME" | awk '{print $1}')
RZ_SHA=$(sha256sum "$SRV/$RZ_NAME" | awk '{print $1}')
printf '%s  %s\n' "$RB_SHA" "$RB_NAME" > "$SRV/rs.sums"
printf '%s  %s\n' "$RZ_SHA" "$RZ_NAME" > "$SRV/rc.sums"
printf '%s  %s\n%s  %s\n' "$RB_SHA" "$RB_NAME" "$RZ_SHA" "$RZ_NAME" > "$TMP/checksums.good"

cat > "$TMP/fakebin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2;;
    -*) shift;;
    *) url="\$1"; shift;;
  esac
done
case "\$url" in
  */"$RB_NAME") cp "$SRV/$RB_NAME" "\$out";;
  *restic*/SHA256SUMS) cp "$SRV/rs.sums" "\$out";;
  */"$RZ_NAME") cp "$SRV/$RZ_NAME" "\$out";;
  *rclone*/SHA256SUMS) cp "$SRV/rc.sums" "\$out";;
  *) echo "unexpected URL \$url" >&2; exit 1;;
esac
EOF
chmod +x "$TMP/fakebin/curl"

{ cat "$TMP/config.env"; echo "GB_BIN=\"$TMP/bin-dl\""; } > "$TMP/config-dl.env"
run_ok "install.sh succeeds when archive matches both checksums.txt and upstream SHA256SUMS" \
  env PATH="$TMP/fakebin:$PATH" GB_CONFIG="$TMP/config-dl.env" GB_CHECKSUMS="$TMP/checksums.good" "$REPO_DIR/install.sh"
check "installed restic and rclone in temp bin/" test -x "$TMP/bin-dl/restic" -a -x "$TMP/bin-dl/rclone"

# Reuse check: replace fake curl with one that always fails; second install.sh must reuse bin-dl without downloading
cat > "$TMP/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl should not be called when bin/ is valid" >&2
exit 99
EOF
chmod +x "$TMP/fakebin/curl"
run_ok "install.sh reuses valid bin/ without downloading" \
  env PATH="$TMP/fakebin:$PATH" GB_CONFIG="$TMP/config-dl.env" GB_CHECKSUMS="$TMP/checksums.good" "$REPO_DIR/install.sh"

# Reuse check when checksums.txt has no entry for the pinned version: valid bin/ must still succeed (exit 0)
: > "$TMP/checksums.empty"
run_ok "install.sh exits 0 when bin/ is valid even if checksums.txt has no entry for the pinned version" \
  env PATH="$TMP/fakebin:$PATH" GB_CONFIG="$TMP/config-dl.env" GB_CHECKSUMS="$TMP/checksums.empty" "$REPO_DIR/install.sh"

# Restore fake curl and test mismatch against pinned checksums.txt (even when upstream SHA256SUMS matches)
cat > "$TMP/fakebin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2;;
    -*) shift;;
    *) url="\$1"; shift;;
  esac
done
case "\$url" in
  */"$RB_NAME") cp "$SRV/$RB_NAME" "\$out";;
  *restic*/SHA256SUMS) cp "$SRV/rs.sums" "\$out";;
  */"$RZ_NAME") cp "$SRV/$RZ_NAME" "\$out";;
  *rclone*/SHA256SUMS) cp "$SRV/rc.sums" "\$out";;
  *) exit 1;;
esac
EOF
chmod +x "$TMP/fakebin/curl"

BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
printf '%s  %s\n%s  %s\n' "$BAD_SHA" "$RB_NAME" "$RZ_SHA" "$RZ_NAME" > "$TMP/checksums.bad"
{ cat "$TMP/config.env"; echo "GB_BIN=\"$TMP/bin-bad\""; } > "$TMP/config-bad.env"
rc=0
PATH="$TMP/fakebin:$PATH" GB_CONFIG="$TMP/config-bad.env" GB_CHECKSUMS="$TMP/checksums.bad" "$REPO_DIR/install.sh" >"$TMP/bad.out" 2>&1 || rc=$?
check "install.sh rejects archive when pinned checksums.txt mismatches (even if upstream SHA256SUMS matches)" test "$rc" != 0
check "no binary installed on checksum mismatch" not test -x "$TMP/bin-bad/restic"
rm -f "$TMP/state/ALERT"

# Also test when pinned checksums.txt matches the archive, but upstream SHA256SUMS mismatches
printf '%s  %s\n' "$BAD_SHA" "$RB_NAME" > "$SRV/rs.sums"
{ cat "$TMP/config.env"; echo "GB_BIN=\"$TMP/bin-bad-up\""; } > "$TMP/config-bad-up.env"
rc=0
PATH="$TMP/fakebin:$PATH" GB_CONFIG="$TMP/config-bad-up.env" GB_CHECKSUMS="$TMP/checksums.good" "$REPO_DIR/install.sh" >"$TMP/bad-up.out" 2>&1 || rc=$?
check "install.sh rejects archive when upstream SHA256SUMS mismatches (even if checksums.txt matches)" test "$rc" != 0
check "no binary installed on upstream checksum mismatch" not test -x "$TMP/bin-bad-up/restic"
rm -f "$TMP/state/ALERT"

# Also verify relative GB_CHECKSUMS works when downloading (resolves before cd "$tmp")
printf '%s  %s\n' "$RB_SHA" "$RB_NAME" > "$SRV/rs.sums"
{ cat "$TMP/config.env"; echo "GB_BIN=\"$TMP/bin-rel\""; } > "$TMP/config-rel.env"
run_ok "install.sh resolves relative GB_CHECKSUMS before cd into temp dir" \
  bash -c 'cd "$1" && PATH="$1/fakebin:$PATH" GB_CONFIG="$1/config-rel.env" GB_CHECKSUMS="checksums.good" "$2/install.sh"' _ "$TMP" "$REPO_DIR"

step "3. Runbooks (docs/runbooks.md) and offline restic repair/rewrite verification"
RB_DOC="$REPO_DIR/docs/runbooks.md"
check "docs/runbooks.md exists" test -s "$RB_DOC"
check "runbook covers repository repair (repair index)" grep -q "repair index" "$RB_DOC"
check "runbook covers repository repair (repair snapshots)" grep -q "repair snapshots" "$RB_DOC"
check "runbook warns never to prune during repair" grep -qi 'never.*prune' "$RB_DOC"
check "runbook covers Drive trash recovery (rclone backend untrash)" grep -q "rclone backend untrash" "$RB_DOC"
check "runbook covers Drive trash recovery (PRUNE_USE_TRASH)" grep -q "PRUNE_USE_TRASH" "$RB_DOC"
check "runbook covers wrong BACKUP_HOST (rewrite --new-host)" grep -q -- "--new-host" "$RB_DOC"
check "runbook covers wrong BACKUP_HOST (restore.sh --any-host fallback)" grep -q -- "--any-host" "$RB_DOC"
check "runbook read-only restic examples do not take locks" python3 - "$RB_DOC" <<'PYNOLOCK'
import re,sys
examples=[]
for line in open(sys.argv[1]):
    if re.match(r'^\s*(?:R_TIMEOUT=\S+\s+)?(?:restic|R|RT)\s+(?:snapshots|ls|stats|find|cat|list|diff|restore)\b',line):
        examples.append(line)
assert examples and all('--no-lock' in line for line in examples)
PYNOLOCK

# Offline verification of runbook restic commands (repair index + rewrite --new-host --forget)
if [[ -x "$REPO_DIR/bin/restic" ]]; then
  PASSF="$TMP/secrets/restic-pass"
  mkdir -p "$TMP/src-data"
  echo "runbook test payload" > "$TMP/src-data/hello.txt"
  rs() { "$REPO_DIR/bin/restic" -r "$TMP/repo" --password-file "$PASSF" "$@"; }
  run_ok "restic init local repo" rs init
  run_ok "backup under wrong host" rs backup --host wronghost --tag auto --tag files=1 "$TMP/src-data"
  run_ok "restic repair index (runbook 1 & 2)" rs repair index
  run_ok "restic check after repair index" rs check
  run_ok "restic rewrite --host wronghost --new-host grokbox --forget (runbook 3)" \
    rs rewrite --host wronghost --new-host grokbox --forget
  snaps_json=$(rs snapshots --json)
  check "rewritten snapshot has hostname grokbox, preserves auto/files=1 tags, no rewrite tag, 0 wronghost snapshots" \
    python3 -c '
import json, sys
s = json.loads(sys.argv[1])
assert len(s) == 1, f"expected 1 snapshot, got {len(s)}"
assert s[0]["hostname"] == "grokbox", s[0]["hostname"]
tags = set(s[0].get("tags") or [])
assert "auto" in tags and "files=1" in tags and "rewrite" not in tags, tags
' "$snaps_json"
fi

step "4. README.md and AGENTS.md links"
check "README.md links docs/runbooks.md" grep -q 'docs/runbooks.md' "$REPO_DIR/README.md"
check "README.md links ci/github-actions-ci.yml.example" grep -q 'ci/github-actions-ci\.yml\.example' "$REPO_DIR/README.md"
check "README.md links checksums.txt" grep -q 'checksums\.txt' "$REPO_DIR/README.md"
check "AGENTS.md references checksums.txt" grep -q "checksums.txt" "$REPO_DIR/AGENTS.md"
check "AGENTS.md references docs/runbooks.md" grep -q "docs/runbooks.md" "$REPO_DIR/AGENTS.md"


check "Main scheduled prompt requires exact parent handoff" grep -Fxq 'EXPORT NOT DONE IN SCHEDULED RUN — parent: run the export loop (B1–B3) now' "$REPO_DIR/docs/routine-main.md"
check "Main parent export loop is numbered B1–B3 with no step after it reusing a B number" bash -c '
  loop=$(sed -n "/^## Parent chat: export loop/,/^## First run/p" "$1")
  grep -q "^B1\. " <<<"$loop" && grep -q "^B2\. " <<<"$loop" && grep -q "^B3\. " <<<"$loop" && ! grep -qE "^B[4-9]\. " <<<"$loop"' _ "$REPO_DIR/docs/routine-main.md"
check "Main scheduled prompt keeps B4–B6 and never runs B1–B3" bash -c '
  sched=$(sed -n "/^## Scheduled run/,/^## Parent chat: export loop/p" "$1")
  grep -q "^B4\. " <<<"$sched" && grep -q "^B6\. " <<<"$sched" && ! grep -qE "^B[1-3]\. " <<<"$sched"' _ "$REPO_DIR/docs/routine-main.md"
check "Assist scheduled prompt requires exact parent handoff" grep -Fxq 'EXPORT NOT DONE IN SCHEDULED RUN — parent: run the export loop now' "$REPO_DIR/docs/routine-assist.md"
check "daily export check is executable and documented" bash -c 'test -x "$1/export-freshness.sh" && grep -q "export-freshness.sh" "$1/README.md"' _ "$REPO_DIR"

step "4. Main alert check (docs/routine-main.md) reports a problem once, recorded only after the parent chat confirms"
AC_REPO="$TMP/alertcheck"; mkdir -p "$AC_REPO/state"
cp "$REPO_DIR/lib.sh" "$REPO_DIR/config.env.example" "$AC_REPO/"
printf '#!/usr/bin/env bash\ncat "%s/doctor.out"\n' "$AC_REPO" > "$AC_REPO/doctor.sh"; chmod +x "$AC_REPO/doctor.sh"
sed -n '/^1\. Run exactly this and read its output:/,/^2\. If any output line starts/p' "$REPO_DIR/docs/routine-main.md" \
  | sed '1d;$d' | sed "s|<REPO>|$AC_REPO|g" > "$AC_REPO/check.sh"
check "alert check step 1 is extracted from the doc" test -s "$AC_REPO/check.sh"
sed -n '/^### Alert check parent chat/,$p' "$REPO_DIR/docs/routine-main.md" | sed -n '/^  ```text/,/^  ```/p' \
  | sed '1d;$d' | sed 's/^  //' | sed "s|<REPO>|$AC_REPO|g" > "$AC_REPO/record.sh"
check "alert check record step is extracted from the doc" test -s "$AC_REPO/record.sh"
ac_new() { env -u GB_CONFIG -u GB_STATE "$@" bash "$AC_REPO/check.sh" > "$AC_REPO/last.out"; sed -n 's/^--- batch: //p' "$AC_REPO/last.out" > "$AC_REPO/batch"; awk 'f && !/^--- batch:/ {print} /^--- new problems:/ {f=1}' "$AC_REPO/last.out"; }
ac_rec() { local b="${1-$(cat "$AC_REPO/batch")}"; sed "s|<BATCH>|$b|" "$AC_REPO/record.sh" | env -u GB_CONFIG -u GB_STATE bash 2>&1; }
printf 'OK alerts: none open\nPROBLEM  scheduler: NOT running\nWARN x: y\nOverall: PROBLEM\n' > "$AC_REPO/doctor.out"
check "alert check: a new doctor PROBLEM is reported" bash -c '[[ "$1" == *"scheduler: NOT running"* && "$1" != *WARN* ]]' _ "$(ac_new)"
b1=$(cat "$AC_REPO/batch")
check "alert check: the first run prints a batch id and records nothing itself" bash -c 'test -n "$1" && test ! -s "$2/state/alert-reported" && test -s "$2/state/alert-pending/$1.tsv"' _ "$b1" "$AC_REPO"
check "alert check: an unconfirmed problem is held back, not repeated an hour later" test -z "$(ac_new)"
check "alert check: a run with nothing new prints no batch line" test ! -s "$AC_REPO/batch"
touch -d '100 minutes ago' "$AC_REPO/state/alert-pending/"*.tsv
check "alert check: a problem never confirmed is handed over again after 90 minutes, in a new batch" bash -c '[[ "$1" == *"scheduler: NOT running"* ]]' _ "$(ac_new)"
b2=$(cat "$AC_REPO/batch")
check "alert check: the repeated handoff has its own batch id" bash -c '[[ -n "$1" && "$1" != "$2" ]]' _ "$b2" "$b1"
check "alert check: the record step needs a real batch id" bash -c '[[ "$1" == *"RECORD FAILED: bad batch id"* && "$2" == *"RECORD FAILED: unknown batch"* ]]' _ "$(ac_rec '../x')" "$(ac_rec 20000101T000000-1)"
check "alert check: recording the confirmed batch stores its key and removes the batch" bash -c '[[ "$1" == "RECORDED $2" ]] && test -s "$3/state/alert-reported" && test ! -e "$3/state/alert-pending/$2.tsv"' _ "$(ac_rec "$b2")" "$b2" "$AC_REPO"
check "alert check: a batch records only once" bash -c '[[ "$1" == *"RECORD FAILED: unknown batch"* ]]' _ "$(ac_rec "$b2")"
printf 'OK alerts: none open\nPROBLEM  scheduler: NOT running for 5 h\nOverall: PROBLEM\n' > "$AC_REPO/doctor.out"
check "alert check: the same problem with a changed detail is not repeated" test -z "$(ac_new)"
echo '[2026-10-29 10:00:00 +03] [backup.sh] boom' > "$AC_REPO/state/ALERT"
check "alert check: a new state/ALERT line is reported" bash -c '[[ "$1" == *"] boom" && "$1" != *scheduler* ]]' _ "$(ac_new)"
printf 'Overall: OK\n' > "$AC_REPO/doctor.out"; rm -f "$AC_REPO/state/ALERT"; ac_new >/dev/null
check "alert check: resolved problems leave the reported list" test ! -s "$AC_REPO/state/alert-reported"
printf 'PROBLEM  scheduler: NOT running\nOverall: PROBLEM\n' > "$AC_REPO/doctor.out"
check "alert check: a problem that comes back is reported again" bash -c '[[ "$1" == *"scheduler: NOT running"* ]]' _ "$(ac_new)"
printf 'PROBLEM  alerts: 1 open\nOverall: PROBLEM\n' > "$AC_REPO/doctor.out"
mkdir -p "$AC_REPO/custom"; echo 'first alert' > "$AC_REPO/custom/ALERT"
check "alert check: GB_STATE is honored and the doctor alerts row is skipped" bash -c '[[ "$1" == "first alert" ]]' _ "$(ac_new GB_STATE="$AC_REPO/custom")"
echo 'second alert' >> "$AC_REPO/custom/ALERT"
check "alert check: a second alert in a custom GB_STATE is reported too" bash -c '[[ "$1" == "second alert" ]]' _ "$(ac_new GB_STATE="$AC_REPO/custom")"
printf 'PROBLEM  scheduler: NOT running\nOverall: PROBLEM\n' > "$AC_REPO/doctor.out"
rm -rf "$AC_REPO/state/alert-current.tsv"; mkdir "$AC_REPO/state/alert-current.tsv"
check "alert check: an unwritable state file gives CHECK FAILED, not nothing new" bash -c '[[ "$(env -u GB_CONFIG -u GB_STATE bash "$1" 2>&1)" == *"CHECK FAILED:"* ]]' _ "$AC_REPO/check.sh"
rmdir "$AC_REPO/state/alert-current.tsv"
rm -rf "$AC_REPO/state/alert-pending"; : > "$AC_REPO/state/alert-pending"
check "alert check: an unwritable batch directory gives CHECK FAILED, not nothing new" bash -c '[[ "$(env -u GB_CONFIG -u GB_STATE bash "$1" 2>&1)" == *"CHECK FAILED:"* ]]' _ "$AC_REPO/check.sh"
rm -f "$AC_REPO/state/alert-pending"
printf 'config.env: no such file\n' > "$AC_REPO/doctor.out"
check "alert check: a crashed doctor gives CHECK FAILED, not nothing new" bash -c '[[ "$(env -u GB_CONFIG -u GB_STATE bash "$1" 2>&1)" == *"CHECK FAILED:"* ]]' _ "$AC_REPO/check.sh"

echo
echo "ci-install test: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
