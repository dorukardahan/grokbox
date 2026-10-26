#!/usr/bin/env bash
# Offline tests for doctor.sh, the weekly test restore, alert dedupe + ALERT_HOOK, the expected-bot roster and
# the Drive report (report.sh). Needs NO Google Drive: local restic repository + a fake rclone in a temp dir.
#   tests/health.sh            run        KEEP_TMP=1 tests/health.sh   keep the temp directory
# shellcheck disable=SC2016,SC2034  # single-quoted `bash -c` / checkx snippets expand later on purpose
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grokbox-health.XXXXXX")"
[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] || { echo "refusing: temp dir $TMP is not under /tmp"; exit 1; }
SCHED_CFG=""; CHILDREN=()
cleanup() { local p; for p in "${CHILDREN[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  [[ -n "$SCHED_CFG" ]] && GB_CONFIG="$SCHED_CFG" "$REPO_DIR/install.sh" --stop-scheduler >/dev/null 2>&1 || true
  [[ -n "${KEEP_TMP:-}" ]] && { echo "kept $TMP"; return; }; chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RCLONE_CONFIG GB_CONFIG
PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N+1)); echo "  ok   - $*"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
checkx() { local d="$1"; shift; if eval "$*"; then pass "$d"; else fail "$d"; fi; }   # checkx DESC 'expr && expr'
all() { local cmd=(); for a in "$@"; do if [[ $a == --and-- ]]; then "${cmd[@]}" || return 1; cmd=(); else cmd+=("$a"); fi; done; "${cmd[@]}"; }   # all CMD --and-- CMD...
run_ok() { local d="$1"; shift; if "$@" >"$TMP/last.out" 2>&1; then pass "$d"; else fail "$d"; sed 's/^/       | /' "$TMP/last.out" | tail -15; fi; }
not() { ! "$@"; }
step() { echo; echo "== $*"; }
[[ -x "$REPO_DIR/bin/restic" ]] || { echo "bin/restic missing: run tests/smoke.sh (or install.sh) once first"; exit 1; }

# --- fixtures: source tree, secrets dir, local repo, fake rclone, a server-export state
SRC="$TMP/src"; SEC="$TMP/gb-secrets"; REPO="$TMP/restic-repo"; SE="$TMP/staging/server-export"; FAKE="$TMP/fakedrive"
mkdir -p "$SRC/docs" "$SRC/agent-data/memory" "$SEC" "$SE/state" "$TMP/fakebin" "$TMP/fakerestic" "$TMP/badpy" "$FAKE"; chmod 700 "$SEC"
python3 - "$SRC" <<'PY'
import os, random, sys
src = sys.argv[1]; random.seed(11)
for i in range(12):
    with open(f"{src}/docs/f{i:02d}.bin", "wb") as f: f.write(random.randbytes(5000 + i))
open(f"{src}/agent-data/memory/notes.md", "w").write("remember: health test\n")
open(f"{src}/agent-data/critical.txt", "w").write("critical file content 0123456789\n")
PY
printf 'health-test-password-%s' "$RANDOM" > "$SEC/restic-pass"; chmod 600 "$SEC/restic-pass"
printf '[fakedrive]\ntype = drive\nscope = drive.file\ntoken = {"access_token":"x"}\n' > "$SEC/rclone.conf"; chmod 600 "$SEC/rclone.conf"
ln -s "$REPO_DIR/bin/restic" "$TMP/fakebin/restic"
cat > "$TMP/fakebin/rclone" <<'FAKE'
#!/usr/bin/env bash
# fake rclone: copyto/moveto write into $FAKE_DRIVE; about/lsd/lsf/mkdir succeed; $FAKE_DRIVE/.fail -> every call fails
pos=(); skip=0
for a in "$@"; do if (( skip )); then skip=0; continue; fi; case "$a" in --config) skip=1;; --*) ;; *) pos+=("$a");; esac; done
[[ -f "$FAKE_DRIVE/.fail" ]] && { echo "fake rclone: simulated failure" >&2; exit 1; }
case "${pos[0]:-}" in
  copyto|moveto) d="${pos[2]#*:}"; mkdir -p "$FAKE_DRIVE/$(dirname "$d")"; cp "${pos[1]}" "$FAKE_DRIVE/$d";;
  about) echo "Total: 16G"; echo "Used: 4G";;
  lsd|lsf|mkdir) :;;
  version) echo "rclone v0.0.0-fake";;
  *) exit 1;;
esac
FAKE
chmod +x "$TMP/fakebin/rclone"
cat > "$TMP/fakerestic/restic" <<'FAKE'
#!/usr/bin/env bash
# failure injection in front of the real restic: FAKE_RESTIC_FAIL=<subcommand> fails at once,
# FAKE_RESTIC_HANG=<subcommand> sleeps first (so the caller's timeout kills it); everything else is passed through
[[ "${FAKE_RESTIC_FAIL:-}" == "$1" ]] && { echo "fake restic: $1 fails" >&2; exit 1; }
[[ "${FAKE_RESTIC_HANG:-}" == "$1" ]] && sleep 30
exec "$REAL_RESTIC" "$@"
FAKE
chmod +x "$TMP/fakerestic/restic"
printf '#!/usr/bin/env bash\necho "fake python3: broken" >&2; exit 1\n' > "$TMP/badpy/python3"; chmod +x "$TMP/badpy/python3"
cat > "$TMP/config.env" <<CFG
GB_BIN="$REPO_DIR/bin"
GB_SECRETS="$SEC"
GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export AGENTS_DIR="$TMP/agents"
export RESTIC_REPOSITORY="$REPO"
export SERVER_EXPORT_DIR="$SE"
DELETED_BOTS_FILE="$TMP/deleted-agents.json"
export FAKE_DRIVE="$FAKE"
BACKUP_ROOTS=("$SRC"); QUICK_ROOTS=("\${BACKUP_ROOTS[@]}")
RESTORE_BASE="$TMP/restore"
KEEP=(--keep-last 100); KEEP_QUICK=(--keep-last 100)
GUARD_MIN_UPTIME_MIN=0; HYDRATION_LOG=""
SQLITE_GLOBS=("$SRC/**/*.db"); BRAIN_AGENT_DIRS=("$SRC/agent-data"); STORES_GLOB="$TMP/nostores/*"
BRAIN_EXPORT_MIN_INTERVAL_MIN=0
TEST_RESTORE_PATHS=("$SRC/agent-data"); TEST_RESTORE_RANDOM_FILES=0
CFG
export GB_CONFIG="$TMP/config.env"
mkcfg() {   # mkcfg NAME LINE... -> path of a config copy with LINEs appended
  local n="$1"; shift; { cat "$TMP/config.env"; printf '%s\n' "$@"; } > "$TMP/config-$n.env"; echo "$TMP/config-$n.env"; }
rs() { "$REPO_DIR/bin/restic" -r "$REPO" --password-file "$SEC/restic-pass" "$@"; }
nsnap() { rs snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }
LOGF="$TMP/logs/backup-$(date +%Y-%m).log"
now_s() { date +%s; }
# server-export fixture: fresh, stale, unreadable, paging (fresh gap), gap (old), empty conversation
mkpos() {   # mkpos [KEY=SHIFT_SECONDS...]: (re)write positions.json; a SHIFT moves that bot's "checked" into the past
  python3 - "$SE/state/positions.json" "$@" <<'PY'
import json, sys, time
f = lambda t: time.strftime('%Y-%m-%d %H:%M:%S%z', time.localtime(t))
now = time.time(); shift = dict(a.split("=") for a in sys.argv[2:])
pos = {"tid-1": {"name": "Test Bot", "total": 10, "max_pos": 9, "lines": 10, "checked": f(now), "last_export": f(now)},
       "tid-2": {"name": "Old Bot", "total": 5, "max_pos": 4, "lines": 5, "checked": f(now - 40 * 3600)},
       "tid-3": {"name": "Hidden Bot", "total": 0, "unreadable": True, "checked": f(now)},
       "tid-4": {"name": "Paging Bot", "total": 100, "max_pos": -1, "lines": 0, "pending": [[90, 99]], "checked": f(now)},
       "tid-5": {"name": "Gap Bot", "total": 100, "max_pos": 49, "lines": 50, "pending": [[90, 99]], "checked": f(now - 2 * 3600)},
       "tid-6": {"name": "Quiet Bot", "total": 0, "max_pos": -1, "lines": 0, "checked": f(now), "last_export": f(now)}}
for k, s in shift.items(): pos[k]["checked"] = f(now - float(s))
json.dump(pos, open(sys.argv[1], "w"), indent=1)
PY
}
mkpos
echo "# index" > "$SE/INDEX.md"; chmod -R go-rwx "$SE"
alert_in() { local c="$1"; shift; GB_CONFIG="$c" bash -c 'source "$1/lib.sh"; shift; alert "$@"' _ "$REPO_DIR" "$@"; }
nalerts() { [[ -f "$TMP/state/ALERT" ]] || { echo 0; return; }; grep -c "$1" "$TMP/state/ALERT" || true; }

step "lib.sh: kv helpers, bounded numbers, weekly slot"
run_ok "lib.sh sources with the example defaults (new settings get defaults)" bash -c 'source "$1/lib.sh"; [[ "$ALERT_DEDUPE_HOURS" == 24 && "$TEST_RESTORE_WEEKDAY" == 0 && "$DRIVE_REPORT" == 1 && ${#EXPECTED_BOTS[@]} == 0 && "$EXPECTED_BOTS_GRACE_MIN" == 60 ]]' _ "$REPO_DIR"
old=$(mkcfg old 'unset ALERT_HOOK ALERT_HOOK_TIMEOUT ALERT_DEDUPE_HOURS DRIVE_REPORT TEST_RESTORE_WEEKDAY TEST_RESTORE_AT EXPECTED_BOTS EXPECTED_BOTS_MAX_HOURS EXPECTED_BOTS_GRACE_MIN DELETED_BOTS_FILE RETIRED_BOTS AGENTS_DIR')
run_ok "an older config.env without the new settings still sources (defaults filled in)" env GB_CONFIG="$old" bash -c 'source "$1/lib.sh"; [[ "$ALERT_DEDUPE_HOURS" == 24 && ${#EXPECTED_BOTS[@]} == 0 && ${#RETIRED_BOTS[@]} == 0 && "$DELETED_BOTS_FILE" == /home/box/agent-data/deleted-agents.json && "$AGENTS_DIR" == /home/box/agent-data/agents ]]' _ "$REPO_DIR"
v=$(bash -c 'source "$1/lib.sh"; kv_write "$GB_STATE/kv.test" "result=ok" "time=42" "note=a=b"; kv_get "$GB_STATE/kv.test" note; kv_get "$GB_STATE/kv.test" missing; kv_get "$GB_STATE/nofile" x; echo end' _ "$REPO_DIR")
check "kv_write/kv_get round trip; missing key/file give empty, never fail" test "$v" = "a=b
end"
v=$(bash -c 'source "$1/lib.sh"; for x in 08 0 42 1e9999 999999999999999999 -5 "" abc 8589934591 8589934592; do printf "%s|%s " "$(num_ok "$x")" "$(epoch_ok "$x")"; done' _ "$REPO_DIR")
check "num_ok/epoch_ok: leading zeros ok, floats/huge/negative/empty/text rejected, epoch bounded (got: $v)" test "$v" = "8|8 0| 42|42 | | | | | 8589934591|8589934591 8589934592| "
# the config sets TZ=UTC, so the expected dates are computed in UTC too
wd=$(TZ=UTC date +%w); wdn=$(( (wd + 1) % 7 ))
slot() { GB_CONFIG="$(mkcfg "slot$1" "TEST_RESTORE_WEEKDAY=$2" "TEST_RESTORE_AT=$3")" bash -c 'source "$1/lib.sh"; test_restore_slot' _ "$REPO_DIR"; }
check "weekly slot: today's weekday after TEST_RESTORE_AT -> today" test "$(slot 1 "$wd" 00:00)" = "$(TZ=UTC date +%F)"
check "weekly slot: today's weekday before TEST_RESTORE_AT -> a week ago" test "$(slot 2 "$wd" 23:59)" = "$(TZ=UTC date -d '-7 days' +%F)"
check "weekly slot: tomorrow's weekday -> 6 days ago" test "$(slot 3 "$wdn" 00:00)" = "$(TZ=UTC date -d '-6 days' +%F)"
check "weekly slot: empty TEST_RESTORE_WEEKDAY -> off (prints nothing)" test -z "$(slot 4 '""' 00:00)"

step "alert dedupe (once per incident, numbers ignored, locked) + status.sh --ack starts a new incident"
alert_in "$GB_CONFIG" "dup test message"; alert_in "$GB_CONFIG" "dup test message"; alert_in "$GB_CONFIG" "another message"
check "two identical alerts + one other -> 2 lines in state/ALERT" test "$(wc -l < "$TMP/state/ALERT")" = 2
check "...and 2 lines in logs/alerts.log" test "$(grep -c 'test message\|another message' "$TMP/logs/alerts.log")" = 2
check "the repeat is noted in the month log" grep -q 'ALERT (repeat 2' "$LOGF"
check "state/alert-seen records the incident with count 2" grep -q ' 2$' "$TMP/state/alert-seen"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
check "--ack removes state/alert-seen" test ! -e "$TMP/state/alert-seen"
alert_in "$GB_CONFIG" "dup test message"
check "after --ack the same text is recorded again (new incident)" test "$(wc -l < "$TMP/state/ALERT")" = 1
backdate() {   # backdate SECONDS: move every incident's first-seen into the past (simulates time passing)
  python3 - "$TMP/state/alert-seen" "$1" <<'PY'
import sys
p, back = sys.argv[1], int(sys.argv[2]); out = []
for l in open(p):
    k, t, c = l.split(); out.append(f"{k} {int(t) - back} {c}\n")
open(p, "w").writelines(out)
PY
}
backdate $((25 * 3600))
alert_in "$GB_CONFIG" "dup test message"
check "after ALERT_DEDUPE_HOURS the same text is recorded again" test "$(wc -l < "$TMP/state/ALERT")" = 2
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
alert_in "$GB_CONFIG" "backup.lock held for 13h by: 4242 backup.sh auto (past job timeout plus grace)"
backdate 3600; alert_in "$GB_CONFIG" "backup.lock held for 14h by: 4242 backup.sh auto (past job timeout plus grace)"
backdate 3600; alert_in "$GB_CONFIG" "backup.lock held for 15h by: 4242 backup.sh auto (past job timeout plus grace)"
check "an alert whose age grows every hour is ONE incident: 1 line in state/ALERT (the first text), count 3" all test "$(nalerts 'held for')" = 1 --and-- grep -q 'held for 13h' "$TMP/state/ALERT" --and-- grep -q ' 3$' "$TMP/state/alert-seen"
check "...the repeats are logged with their current text" grep -q 'repeat 3.*held for 15h' "$LOGF"
alert_in "$GB_CONFIG" "backup.lock held for 15h by: 4242 check.sh (past job timeout plus grace)"
check "a different job in the text is a different incident" test "$(nalerts 'held for')" = 2
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
for _ in $(seq 1 20); do alert_in "$GB_CONFIG" "parallel storm" & done; wait
check "20 concurrent identical alerts: exactly 1 recorded, 20 counted (state/alert.lock serializes them)" all test "$(nalerts 'parallel storm')" = 1 --and-- grep -q ' 20$' "$TMP/state/alert-seen" --and-- test "$(wc -l < "$TMP/state/alert-seen")" = 1
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "ALERT_HOOK (off by default; stdin + GB_ALERT_MSG; timeout; failures logged; never recursive)"
alert_in "$GB_CONFIG" "no hook configured"
check "no hook by default: no alert-hook.log" test ! -e "$TMP/logs/alert-hook.log"
hk=$(mkcfg hook "ALERT_HOOK='cat >> $TMP/hook.out; printf \"env:%s\\n\" \"\$GB_ALERT_MSG\" >> $TMP/hook.out'")
alert_in "$hk" "hook test"; alert_in "$hk" "hook test"
check "hook ran once for two identical alerts, got the text on stdin and in GB_ALERT_MSG" test "$(grep -c 'hook test' "$TMP/hook.out")" = 2 -a "$(grep -c '^env:' "$TMP/hook.out")" = 1
check "hook text carries timestamp + script name" grep -qE '^\[[0-9-]+ [0-9:]+ [A-Z]+\] \[_\] hook test$' "$TMP/hook.out"
hf=$(mkcfg hookfail "ALERT_HOOK='exit 3'")
alert_in "$hf" "hook fails"
checkx "a failing hook: alert still recorded, failure logged, not fatal" 'grep -q "hook fails" "$TMP/state/ALERT" && grep -q "alert hook exited rc=3" "$LOGF"'
ht=$(mkcfg hooktimeout "ALERT_HOOK='sleep 30'" "ALERT_HOOK_TIMEOUT=1")
t0=$(now_s); alert_in "$ht" "hook hangs"; t1=$(now_s)
check "a hung hook is killed after ALERT_HOOK_TIMEOUT (took $((t1-t0)) s)" test $((t1 - t0)) -lt 15
check "...and logged as rc=124" grep -q 'alert hook exited rc=124' "$LOGF"
cat > "$TMP/hook-recurse.sh" <<EOS
#!/usr/bin/env bash
echo ran >> "$TMP/hook.out"
GB_CONFIG="$TMP/config-recurse.env" bash -c 'source "$REPO_DIR/lib.sh"; alert "raised from inside the hook"'
EOS
chmod +x "$TMP/hook-recurse.sh"; mkcfg recurse "ALERT_HOOK='$TMP/hook-recurse.sh'" >/dev/null
t0=$(now_s); alert_in "$TMP/config-recurse.env" "outer alert"; t1=$(now_s)
checkx "a hook that raises an alert does not run the hook again and does not deadlock on the alert lock (ran once, both recorded, $((t1-t0)) s)" 'test "$(grep -c "^ran$" "$TMP/hook.out")" = 1 && grep -q "raised from inside the hook" "$TMP/state/ALERT" && grep -q "outer alert" "$TMP/state/ALERT" && test $((t1 - t0)) -lt 20'
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "expected-bot roster (expected-bots.sh): completeness, in-progress grace, no-export alert, stable alerts"
rc=0; out=$("$REPO_DIR/expected-bots.sh") || rc=$?
checkx "empty roster: 'no roster configured', exit 0" 'test "$rc" = 0 && grep -q "no roster" <<<"$out"'
eb=$(mkcfg bots 'EXPECTED_BOTS=("test bot" "tid-2" "Hidden Bot" "Ghost Bot" "Gap Bot" "Paging Bot" "Quiet Bot")')
rc=0; out=$(GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "missing bots -> exit 1, listing why (never exported / not readable / stale / incomplete)" 'test "$rc" = 1 && [[ "$out" == *"Ghost Bot (never exported)"* && "$out" == *"Hidden Bot (not readable)"* && "$out" == *"tid-2 (last export check 40 h ago)"* && "$out" == *"Gap Bot (export incomplete: 50 of 100 messages, pending pages)"* ]]'
checkx "...a fresh gap is 'export in progress', not present and not missing: present 2 of 7" '[[ "$out" == *"present: 2 of 7"* && "$out" == *"export in progress: Paging Bot (export incomplete: 0 of 100 messages, pending pages, checked 0 min ago)"* ]]'
GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true; GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true
check "--alert raises one deduped alert" test "$(nalerts 'expected bots missing')" = 1
check "the alert text carries no changing ages (stable per incident)" all not grep -q '40 h ago' "$TMP/state/ALERT" --and-- grep -q 'tid-2 (last export check older than 26 h)' "$TMP/state/ALERT" --and-- grep -q 'Gap Bot (export incomplete)' "$TMP/state/ALERT"
mkpos tid-2=$((41 * 3600)) tid-5=$((3 * 3600))
GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true
check "an hour later (ages 41 h / 3 h): still the same incident, no second alert" test "$(nalerts 'expected bots missing')" = 1
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
ok1=$(mkcfg bots-ok 'EXPECTED_BOTS=("Test Bot" "Quiet Bot")')
rc=0; out=$(GB_CONFIG="$ok1" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "name match (case-insensitive / slug) + a legitimately empty conversation -> all present, exit 0" 'test "$rc" = 0 && grep -q "all 2 expected bots present and complete" <<<"$out"'
pg=$(mkcfg bots-paging 'EXPECTED_BOTS=("Paging Bot")')
rc=0; out=$(GB_CONFIG="$pg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "a bot with zero exported lines and pending pages is never 'present': 'in progress', exit 0, no alert" 'test "$rc" = 0 && [[ "$out" == "0 of 1 expected bots present, export still in progress"* ]] && ! grep -q "expected bots" "$TMP/state/ALERT" 2>/dev/null'
mkpos tid-4=$((2 * 3600))
rc=0; out=$(GB_CONFIG="$pg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "...the same gap 2 h later (older than EXPECTED_BOTS_GRACE_MIN) is missing: exit 1 + alert" 'test "$rc" = 1 && [[ "$out" == *"Paging Bot (export incomplete: 0 of 100 messages, pending pages)"* ]] && test "$(nalerts "expected bots missing")" = 1'
mkpos; "$REPO_DIR/status.sh" --ack >/dev/null 2>&1
nox=$(mkcfg bots-noexport 'EXPECTED_BOTS=("Test Bot")' "export SERVER_EXPORT_DIR=$TMP/nowhere")
now_s > "$TMP/state/first-start"
rc=0; out=$(GB_CONFIG="$nox" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "no export yet, just installed -> exit 2, no alert (installation grace)" 'test "$rc" = 2 && grep -q "no server-side export yet" <<<"$out" && test "$(nalerts "expected bots")" = 0'
echo $(( $(now_s) - 27 * 3600 )) > "$TMP/state/first-start"
rc=0; GB_CONFIG="$nox" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || rc=$?; GB_CONFIG="$nox" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true
checkx "no export 27 h after the first start -> exit 2 + one deduped alert" 'test "$rc" = 2 && test "$(nalerts "expected bots: no server-side export at all")" = 1'
rm -f "$TMP/state/first-start"; "$REPO_DIR/status.sh" --ack >/dev/null 2>&1
GB_CONFIG="$nox" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true
check "no export and no first-start marker (unbounded) -> alert" test "$(nalerts 'expected bots: no server-side export at all')" = 1
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
echo '{"tid-1": "garbage"}' > "$SE/state/positions.json"
rc=0; out=$(GB_CONFIG="$ok1" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "a garbled record never crashes the check (exit 1, 'never exported')" 'test "$rc" = 1 && [[ "$out" == *"Test Bot (never exported)"* ]]'
mkpos

out=$("$REPO_DIR/expected-bots.sh" --help)
check "roster help includes scheduler integration" grep -q 'scheduler.sh runs it with --alert' <<<"$out"

# An older deleted record must not hide a recreated bot with the same name.
python3 - "$SE/state/positions.json" <<'PYFIX'
import json, sys
p = json.load(open(sys.argv[1]))
p["tid-new"] = dict(p["tid-2"])
p["tid-later"] = dict(p["tid-2"], checked=p["tid-1"]["checked"])
json.dump(p, open(sys.argv[1], "w"))
PYFIX
for retirement in deleted retired; do
  echo '{"agents":{"tid-2":{}}}' > "$TMP/deleted-agents.json"
  if [[ "$retirement" == retired ]]; then
    cfg=$(mkcfg bots-recreated 'EXPECTED_BOTS=("Old Bot")' 'DELETED_BOTS_FILE=""' 'RETIRED_BOTS=("tid-2")')
  else
    cfg=$(mkcfg bots-recreated 'EXPECTED_BOTS=("Old Bot")')
  fi
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
  checkx "$retirement old id: first active same-name candidate is stale, exit 1 and alert" 'test "$rc" = 1 && test "$out" = "missing from the server-side export: Old Bot (last export check 40 h ago); present: 0 of 1" && test "$(nalerts "Old Bot (last export check older than 26 h)")" = 1'
  "$REPO_DIR/status.sh" --ack >/dev/null 2>&1
done

# Inventory detects a recreated bot before its first export; all fixtures stay local.
echo '{"tid-old":{"name":"Helper Bot","total":5,"max_pos":4}}' > "$SE/state/positions.json"
echo '{"agents":{"tid-old":{}}}' > "$TMP/deleted-agents.json"
mkdir -p "$TMP/agents/tid-new"
echo '{"name":"helper-bot"}' > "$TMP/agents/tid-new/profile.json"
inv=$(mkcfg bots-inventory 'EXPECTED_BOTS=("Helper Bot")')
rc=0; out=$(GB_CONFIG="$inv" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "unexported same-name replacement: missing, retained predecessor history, stable alert" 'test "$rc" = 1 && test "$out" = "missing from the server-side export: Helper Bot (never exported); present: 0 of 1; deleted: Helper Bot (deleted): history kept (5 messages)" && test "$(nalerts "Helper Bot (never exported)")" = 1 && ! grep -q "deleted" "$TMP/state/ALERT"'
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
for kind in empty missing file garbled nonobject nonstring missing-profile deleted retired-id retired-name; do
  cfg="$inv"
  case "$kind" in
    empty) mkdir -p "$TMP/empty-agents"; cfg=$(mkcfg bots-inventory-empty 'EXPECTED_BOTS=("Helper Bot")' "AGENTS_DIR=$TMP/empty-agents");;
    missing) cfg=$(mkcfg bots-inventory-missing 'EXPECTED_BOTS=("Helper Bot")' "AGENTS_DIR=$TMP/no-agents");;
    file) echo '{}' > "$TMP/agents-file"; cfg=$(mkcfg bots-inventory-file 'EXPECTED_BOTS=("Helper Bot")' "AGENTS_DIR=$TMP/agents-file");;
    garbled) echo '{broken' > "$TMP/agents/tid-new/profile.json";;
    nonobject) echo '[]' > "$TMP/agents/tid-new/profile.json";;
    nonstring) echo '{"name":42}' > "$TMP/agents/tid-new/profile.json";;
    missing-profile) rm "$TMP/agents/tid-new/profile.json";;
    deleted) echo '{"name":"Helper Bot"}' > "$TMP/agents/tid-new/profile.json"; echo '{"agents":{"tid-old":{},"tid-new":{}}}' > "$TMP/deleted-agents.json";;
    retired-id) echo '{"agents":{"tid-old":{}}}' > "$TMP/deleted-agents.json"; cfg=$(mkcfg bots-inventory-retired 'EXPECTED_BOTS=("Helper Bot")' 'RETIRED_BOTS=("tid-new")');;
    retired-name) cfg=$(mkcfg bots-inventory-retired-name 'EXPECTED_BOTS=("Helper Bot")' 'RETIRED_BOTS=("helper-bot")');;
  esac
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert 2>"$TMP/inventory.err") || rc=$?
  checkx "$kind inventory: predecessor stays exempt, no warnings or alert" 'test "$rc" = 0 && test "$out" = "no active expected bots; deleted: Helper Bot (deleted): history kept (5 messages)" && test ! -s "$TMP/inventory.err" && test "$(nalerts "expected bots")" = 0'
done
# A file named like an agent is not inventory; an id still matches without a valid profile.
mkdir -p "$TMP/file-agents"
echo '{}' > "$TMP/file-agents/Helper Bot"
cfg=$(mkcfg bots-inventory-file-entry 'EXPECTED_BOTS=("Helper Bot")' "AGENTS_DIR=$TMP/file-agents")
rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "non-directory inventory entry is ignored" 'test "$rc" = 0 && [[ "$out" == "no active expected bots; deleted: Helper Bot (deleted): history kept (5 messages)" ]]'
echo '{broken' > "$TMP/agents/tid-new/profile.json"
cfg=$(mkcfg bots-inventory-id 'EXPECTED_BOTS=("tid-new")')
rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "id roster with garbled inventory profile remains never exported" 'test "$rc" = 1 && [[ "$out" == *"tid-new (never exported)"* ]]'
echo '{"name":"Helper Bot"}' > "$TMP/agents/tid-new/profile.json"
python3 - "$SE/state/positions.json" <<'PYFIX'
import json, sys, time
p = json.load(open(sys.argv[1]))
p["tid-new"] = {"name": "Helper Bot", "total": 5, "max_pos": 4,
                "checked": time.strftime('%Y-%m-%d %H:%M:%S%z')}
json.dump(p, open(sys.argv[1], "w"))
PYFIX
rc=0; out=$(GB_CONFIG="$inv" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "exported replacement is present and complete" 'test "$rc" = 0 && [[ "$out" == "all 1 expected bots present and complete"* ]] && test "$(nalerts "expected bots")" = 0'
# Inventory-name resolution also uses an existing record whose stored name differs.
python3 - "$SE/state/positions.json" <<'PYFIX'
import json, sys
p = json.load(open(sys.argv[1])); p["tid-new"]["name"] = "Renamed Bot"
json.dump(p, open(sys.argv[1], "w"))
PYFIX
rc=0; out=$(GB_CONFIG="$inv" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "inventory replacement uses its existing export record by id" 'test "$rc" = 0 && [[ "$out" == "all 1 expected bots present and complete"* && "$out" == *"; deleted: Helper Bot (deleted): history kept (5 messages)" ]]'
rm -rf "$TMP/agents"

# Empty slugs must not equate unrelated names, or retire nameless merger records.
echo '{"tid-nameless":{"max_pos":0,"lines":1}}' > "$SE/state/positions.json"
for retired in 'RETIRED_BOTS=("Бот")' 'RETIRED_BOTS=("")' 'RETIRED_BOTS=("!!!")'; do
  cfg=$(mkcfg bots-empty-slug 'EXPECTED_BOTS=("tid-nameless")' 'DELETED_BOTS_FILE=""' "$retired")
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh") || rc=$?
  checkx "$retired does not retire a nameless active record" 'test "$rc" = 1 && test "$out" = "missing from the server-side export: tid-nameless (last export check unknown); present: 0 of 1"'
done
for roster in 'EXPECTED_BOTS=("Бот")' 'EXPECTED_BOTS=("")' 'EXPECTED_BOTS=("!!!")'; do
  cfg=$(mkcfg bots-empty-lookup "$roster" 'DELETED_BOTS_FILE=""')
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh") || rc=$?
  checkx "$roster does not resolve to a nameless record via an empty slug" 'test "$rc" = 1 && [[ "$out" == *"(never exported); present: 0 of 1" ]]'
done
mkpos
for history in gap pending complete zero negative; do
  case "$history" in
    gap) max_pos=49; pending='[]'; expected='50 of 100 messages, export incomplete';;
    pending) max_pos=99; pending='[[90,99]]'; expected='100 of 100 messages, export incomplete';;
    complete) max_pos=120; pending='[]'; expected='100 messages';;
    zero) max_pos=-1; pending='[[90,99]]'; expected='';;
    negative) max_pos=-5; pending='[]'; expected='';;
  esac
  printf '{"tid-history":{"total":100,"max_pos":%s,"pending":%s}}\n' "$max_pos" "$pending" > "$SE/state/positions.json"
  cfg=$(mkcfg bots-kept 'EXPECTED_BOTS=("tid-history")' 'DELETED_BOTS_FILE=""' 'RETIRED_BOTS=("tid-history")')
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
  if [[ -n "$expected" ]]; then
    expected="history kept ($expected)"
  else
    expected='nothing exported (0 of 100 messages)'
  fi
  checkx "$history deleted history: accurate kept count and completeness, no alert" 'test "$rc" = 0 && test "$out" = "no active expected bots; deleted: tid-history (deleted): $expected" && test "$(nalerts "expected bots")" = 0'
done
mkpos

# A failed read must not hide history already exported before deletion.
for fixture in '0 4 true 5' '0 4 false 5' '3 4 true 3' '8 4 true 5'; do
  read -r total max_pos unreadable kept <<< "$fixture"
  printf '{"tid-history":{"total":%s,"max_pos":%s,"unreadable":%s}}\n' "$total" "$max_pos" "$unreadable" > "$SE/state/positions.json"
  cfg=$(mkcfg bots-unreadable-kept 'EXPECTED_BOTS=("tid-history")' 'DELETED_BOTS_FILE=""' 'RETIRED_BOTS=("tid-history")')
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
  checkx "deleted history survives failed reads ($fixture)" 'test "$rc" = 0 && test "$out" = "no active expected bots; deleted: tid-history (deleted): history kept ($kept messages, no longer readable)" && test "$(nalerts "expected bots")" = 0'
done
mkpos

# Display the raw name, distinguish id entries, and never double the deletion suffix.
echo '{"tid-long-id":{"name":"Helper Bot (deleted)","total":5,"max_pos":4}}' > "$SE/state/positions.json"
cfg=$(mkcfg bots-label 'EXPECTED_BOTS=("tid-long-id")' 'DELETED_BOTS_FILE=""' 'RETIRED_BOTS=("tid-long-id")')
rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "deleted label is idempotent and id roster suffix is eight characters" 'test "$rc" = 0 && test "$out" = "no active expected bots; deleted: Helper Bot (deleted) [tid-long]: history kept (5 messages)"'
mkpos

# Deleted fixtures never consult the box's real deleted-agent list.
echo '{"version":1,"agents":{"tid-2":{"upstream":"pending"},"bot-gone":{},"tid-3":{}}}' > "$TMP/deleted-agents.json"
del=$(mkcfg bots-deleted 'EXPECTED_BOTS=("bot-gone" "old-bot-name" "Hidden Bot" "Test Bot")' 'RETIRED_BOTS=("old bot name")')
rc=0; out=$(GB_CONFIG="$del" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "absent and unreadable deleted bots: exit 0, no alert; active bot still complete" 'test "$rc" = 0 && [[ "$out" == "all 1 expected bots present and complete"* && "$out" == *"bot-gone (deleted): never exported"* && "$out" == *"Hidden Bot (deleted): never exported"* && "$out" == *"old-bot-name (deleted): never exported"* ]] && test "$(nalerts "expected bots")" = 0'
del=$(mkcfg bots-history 'EXPECTED_BOTS=("old-bot" "Old Bot")')
rc=0; out=$(GB_CONFIG="$del" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "all deleted, including stale history: exit 0 and no alert" 'test "$rc" = 0 && [[ "$out" == "no active expected bots; deleted:"* && "$out" == *"Old Bot (deleted): history kept (5 messages)"* ]] && test "$(nalerts "expected bots")" = 0'
for payload in '{"version":1,"tid-2":{}}' '{"agents":["tid-2"]}' '{"agents":[{"id":"tid-2"}]}' '["tid-2"]' '[{"id":"tid-2"}]' '[{"id":"tid-2"},null,3,{"id":[]}]' '{"tid-2":{},"version":1}'; do
  printf '%s\n' "$payload" > "$TMP/deleted-agents.json"
  # Resolve a slug to its record id before consulting the list.
  cfg=$(mkcfg bots-shape 'EXPECTED_BOTS=("old-bot")')
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
  checkx "deleted list shape $payload resolves name slug to id" 'test "$rc" = 0 && [[ "$out" == *"(deleted): history kept (5 messages)"* ]] && test "$(nalerts "expected bots")" = 0'
done
cfg=$(mkcfg bots-mixed 'EXPECTED_BOTS=("Ghost Bot" "Old Bot")')
rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "active missing alongside deleted: exit 1; alert contains only active bot" 'test "$rc" = 1 && [[ "$out" == "missing from the server-side export: Ghost Bot (never exported); present: 0 of 1; deleted:"* ]] && test "$(nalerts "Ghost Bot (never exported)")" = 1 && ! grep -q "Old Bot\|deleted" "$TMP/state/ALERT"'
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
for kind in missing garbled empty directory; do
  file="$TMP/deleted-$kind.json"
  case "$kind" in garbled) echo 'not JSON' > "$file";; empty) touch "$file";; directory) mkdir "$file";; esac
  cfg=$(mkcfg bots-invalid 'EXPECTED_BOTS=("Old Bot")' "DELETED_BOTS_FILE=$file")
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh") || rc=$?
  checkx "$kind deleted list: stale active bot still missing, exit 1" 'test "$rc" = 1 && test "$out" = "missing from the server-side export: Old Bot (last export check 40 h ago); present: 0 of 1"'
done
cfg=$(mkcfg bots-retired 'EXPECTED_BOTS=("tid-2")' 'DELETED_BOTS_FILE=""' 'RETIRED_BOTS=("OLD BOT")')
rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "retired name matches resolved record: exit 0, history kept, no alert" 'test "$rc" = 0 && [[ "$out" == *"Old Bot (deleted) [tid-2]: history kept (5 messages)"* ]] && test "$(nalerts "expected bots")" = 0'
cfg=$(mkcfg bots-disabled 'EXPECTED_BOTS=("tid-2")' 'DELETED_BOTS_FILE=""')
rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "explicit empty deleted-list path disables it" 'test "$rc" = 1 && [[ "$out" == *"tid-2 (last export check 40 h ago)"* ]]'
for roster in 'EXPECTED_BOTS=("tid-2")' 'EXPECTED_BOTS=("tid-2" "bot-a")'; do
  cfg=$(mkcfg bots-noexport-deleted "$roster" "export SERVER_EXPORT_DIR=$TMP/nowhere")
  rc=0; out=$(GB_CONFIG="$cfg" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
  if [[ "$roster" == *bot-a* ]]; then
    checkx "no positions: only active bots unverified, exit 2 and active count in alert" 'test "$rc" = 2 && [[ "$out" == "no server-side export yet (1 expected bots unverified;"* ]] && grep -q "(1 expected bots unverified," "$TMP/state/ALERT" && ! grep -q "tid-2\|deleted" "$TMP/state/ALERT"'
  else
    checkx "no positions and all deleted: exit 0, no alert" 'test "$rc" = 0 && [[ "$out" == "no active expected bots; deleted: tid-2 (deleted): never exported" ]] && test "$(nalerts "expected bots")" = 0'
  fi
done
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "backup + weekly test restore (critical files, sha256 compare, result file, lock, failures)"
rs init >/dev/null 2>&1
run_ok "backup.sh (auto)" "$REPO_DIR/backup.sh"
check "1 snapshot" test "$(nsnap)" = 1
run_ok "test-restore.sh --weekly" "$REPO_DIR/test-restore.sh" --weekly
tr="$TMP/state/test-restore.result"
kv() { bash -c 'source "$1/lib.sh"; kv_get "$2" "$3"' _ "$REPO_DIR" "$1" "$2"; }
nf=$(kv "$tr" files)
check "test-restore.result: result=ok, files>0, mismatches=0" test "$(kv "$tr" result)" = ok -a "$nf" -gt 0 -a "$(kv "$tr" mismatches)" = 0
check "with TEST_RESTORE_RANDOM_FILES=0 only critical files were sampled: config + agent-data + staging ($nf files)" test "$nf" -ge 4
check "result file says weekly" grep -q '(weekly)' "$TMP/state/test-restore-result.txt"
check "last-test-restore written, restore dir removed" test -s "$TMP/state/last-test-restore" -a -z "$(find "$TMP/restore" -maxdepth 1 -name 'restore-test-*' 2>/dev/null)"
python3 - "$SRC/agent-data/critical.txt" <<'PY'
import os,sys
p=sys.argv[1]; st=os.stat(p); d=open(p,"rb").read()
open(p,"wb").write(b"X"+d[1:]); os.utime(p,(st.st_atime,st.st_mtime))   # same size + mtime, different content
PY
rc=0; "$REPO_DIR/test-restore.sh" --weekly >/dev/null 2>&1 || rc=$?
check "a live file whose content changed without mtime change -> mismatch, exit 6" test "$rc" = 6
check "test-restore.result: result=failed, mismatches=1" test "$(kv "$tr" result)" = failed -a "$(kv "$tr" mismatches)" = 1
check "ALERT names the weekly test restore" grep -q 'TEST RESTORE FAILED (weekly)' "$TMP/state/ALERT"
check "restore dir removed after a failure too" test -z "$(find "$TMP/restore" -maxdepth 1 -name 'restore-test-*' 2>/dev/null)"
( exec 7>>"$TMP/state/backup.lock"; flock 7; exec sleep 30 ) & LP=$!; sleep 1
rc=0; LOCK_WAIT=1 "$REPO_DIR/test-restore.sh" --weekly >/dev/null 2>&1 || rc=$?
check "lock busy -> exit 75 (scheduler retries next minute)" test "$rc" = 75
check "...and the lock-busy exit leaves the last result untouched (still failed)" test "$(kv "$tr" result)" = failed
kill "$LP" 2>/dev/null || true; wait "$LP" 2>/dev/null || true
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
python3 - "$SRC/agent-data/critical.txt" <<'PY'
import os,sys
p=sys.argv[1]; st=os.stat(p); d=open(p,"rb").read(); open(p,"wb").write(b"c"+d[1:]); os.utime(p,(st.st_atime,st.st_mtime))
PY
run_ok "test-restore.sh --weekly succeeds again (live file restored)" "$REPO_DIR/test-restore.sh" --weekly
check "result=ok again" test "$(kv "$tr" result)" = ok
fr=$(mkcfg fakerestic "GB_BIN=$TMP/fakerestic" "export REAL_RESTIC=$REPO_DIR/bin/restic" 'RESTIC_TIMEOUT=2')
rc=0; FAKE_RESTIC_FAIL=snapshots GB_CONFIG="$fr" "$REPO_DIR/test-restore.sh" --weekly >/dev/null 2>&1 || rc=$?
check "restic snapshots fails -> exit 6, result=failed replaces the earlier ok, alert" all test "$rc" = 6 --and-- test "$(kv "$tr" result)" = failed --and-- grep -q 'TEST RESTORE FAILED (weekly): cannot list snapshots' "$TMP/state/ALERT"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1; run_ok "ok run in between" "$REPO_DIR/test-restore.sh" --weekly
t0=$(now_s); rc=0; FAKE_RESTIC_HANG=ls GB_CONFIG="$fr" "$REPO_DIR/test-restore.sh" --weekly >/dev/null 2>&1 || rc=$?
check "restic ls hangs past RESTIC_TIMEOUT -> killed (rc 124 in the alert), exit 6, result=failed ($(( $(now_s) - t0 )) s)" all test "$rc" = 6 --and-- test "$(kv "$tr" result)" = failed --and-- grep -q 'cannot read snapshot .*rc=124' "$TMP/state/ALERT" --and-- test $(( $(now_s) - t0 )) -lt 25
check "restore dir removed after the timeout too" test -z "$(find "$TMP/restore" -maxdepth 1 -name 'restore-test-*' 2>/dev/null)"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1; run_ok "ok run in between" "$REPO_DIR/test-restore.sh" --weekly
ro=$(mkcfg restore-ro "RESTORE_BASE=$TMP/no-such-dir/sub")
mkdir -p "$TMP/no-such-dir"; chmod 000 "$TMP/no-such-dir"
rc=0; GB_CONFIG="$ro" "$REPO_DIR/test-restore.sh" --weekly >/dev/null 2>&1 || rc=$?
chmod 700 "$TMP/no-such-dir"
check "a setup failure (restore dir cannot be created) also ends in result=failed, exit 6, alert" all test "$rc" = 6 --and-- test "$(kv "$tr" result)" = failed --and-- grep -q 'TEST RESTORE FAILED (weekly): unexpected failure' "$TMP/state/ALERT"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1; run_ok "ok run at the end" "$REPO_DIR/test-restore.sh" --weekly

step "report.sh: local report, Drive upload via fake rclone, failure visibility, no ids, zero values, locking"
SID=$(rs snapshots --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)[-1]["short_id"])')
run_ok "report.sh (local repository: written, not uploaded)" "$REPO_DIR/report.sh"
RP="$TMP/state/latest-backup-report.txt"
check "report written" test -s "$RP"
checkx "report: result complete (from last-backup.result), files from the run, test restore ok" 'grep -q "^Result: *complete" "$RP" && grep -qE "^Files: *[0-9,]+$" "$RP" && grep -q "Last test restore:.*ok" "$RP"'
check "report holds no paths, secrets or snapshot ids" not grep -qF -e "$TMP" -e "/home/" -e "$(cat "$SEC/restic-pass")" -e "$SID" -e "Snapshot:" "$RP"
check "log says locally only" grep -q 'not an rclone: repository' "$LOGF"
check "no upload status for a local repository" test ! -e "$TMP/state/report-upload.status"
cp "$TMP/state/last-backup.result" "$TMP/lbr.keep"
printf 'result=failed\ntime=%s\nsnapshot=\nfiles=0\nbytes=0\nadded=0\nduration_s=0\nunreadable=0\n' "$(now_s)" > "$TMP/state/last-backup.result"
run_ok "report.sh after a failed run with zero counts" "$REPO_DIR/report.sh" --no-upload
checkx "valid zeros are shown as 0, not replaced by the previous snapshot's summary" 'grep -q "^Result: *failed" "$RP" && grep -q "^Files: *0$" "$RP" && grep -q "^Added this run: *0 B" "$RP" && grep -q "^Duration: *0 s" "$RP" && ! grep -q "$SID" "$RP"'
printf 'result=complete\ntime=%s\nsnapshot=%s\n' "$(now_s)" "$SID" > "$TMP/state/last-backup.result"
run_ok "report.sh with a result that names the newest snapshot but lacks the counts" "$REPO_DIR/report.sh" --no-upload
checkx "...the snapshot summary fills in files/size (same run), id still not printed" 'grep -qE "^Files: *[1-9][0-9,]*$" "$RP" && ! grep -q "$SID" "$RP"'
printf 'result=complete\ntime=%s\nsnapshot=0000beef\n' "$(now_s)" > "$TMP/state/last-backup.result"
run_ok "report.sh with a result for a different snapshot and no counts" "$REPO_DIR/report.sh" --no-upload
check "...no borrowing from another run: Files unknown" grep -q '^Files: *unknown' "$RP"
rm -f "$TMP/state/last-backup.result"
run_ok "report.sh without last-backup.result (legacy state files)" "$REPO_DIR/report.sh" --no-upload
checkx "...legacy fallback: result complete from last-success, files from the snapshot summary" 'grep -q "^Result: *complete" "$RP" && grep -qE "^Files: *[1-9][0-9,]*$" "$RP"'
cp "$TMP/lbr.keep" "$TMP/state/last-backup.result"
for _ in 1 2 3; do "$REPO_DIR/report.sh" --no-upload >/dev/null 2>&1 & done; wait
check "3 concurrent report.sh runs: report intact (ends with the schedule line), no scratch dirs left" all grep -q '^This file is rewritten' "$RP" --and-- test -z "$(find "$TMP/state" -maxdepth 1 -name 'report.*' -type d)"
rcl=$(mkcfg rclone "GB_BIN=$TMP/fakebin" 'GB_REMOTE=fakedrive' 'GB_FOLDER=GrokBox/restic' 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"' "GB_STATE=$TMP/state-rc")
mkdir -p "$TMP/state-rc"
printf 'result=complete\ntime=%s\nsnapshot=abc12345\nfiles=4321\nbytes=123456789\nadded=1048576\nduration_s=125\nunreadable=0\n' "$(now_s)" > "$TMP/state-rc/last-backup.result"
printf 'result=ok\ntime=%s\npruned=1\n' "$(( $(now_s) - 3600 ))" > "$TMP/state-rc/last-check.result"
printf 'result=ok\ntime=%s\nfiles=25\nmismatches=0\n' "$(( $(now_s) - 86400 ))" > "$TMP/state-rc/test-restore.result"
run_ok "report.sh with an rclone: repository (fake rclone)" env GB_CONFIG="$rcl" "$REPO_DIR/report.sh"
UP="$FAKE/GrokBox/latest-backup-report.txt"
check "uploaded into the PARENT of GB_FOLDER, not into restic/" test -s "$UP" -a ! -e "$FAKE/GrokBox/restic/latest-backup-report.txt"
check "uploaded file equals the local report" cmp -s "$UP" "$TMP/state-rc/latest-backup-report.txt"
check "report uses last-backup.result: files 4,321; 2 min 5 s; added 1.0 MB; prune yes; test restore 25 files" bash -c 'grep -q "4,321" "$1" && grep -q "2 min 5 s" "$1" && grep -q "1.0 MB" "$1" && grep -q "prune: yes" "$1" && grep -q "25 files, 0 mismatches" "$1"' _ "$UP"
check "the uploaded report contains no snapshot id" not grep -q abc12345 "$UP"
check "report-upload.status = ok" grep -q '^result=ok' "$TMP/state-rc/report-upload.status"
touch "$FAKE/.fail"
run_ok "report.sh exits 0 when the upload fails" env GB_CONFIG="$rcl" "$REPO_DIR/report.sh"
check "report-upload.status = failed" grep -q '^result=failed' "$TMP/state-rc/report-upload.status"
GB_CONFIG="$rcl" "$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
check "status.sh --local shows the failed upload" grep -q '!! Drive report: upload .* FAILED' "$TMP/status.out"
GB_CONFIG="$rcl" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "doctor.sh shows WARN for the failed upload" grep -q '^WARN *drive report: upload .* FAILED' "$TMP/doc.out"
rm -f "$FAKE/.fail" "$TMP/state-rc/report-upload.status"
np=$(mkcfg noparent "GB_BIN=$TMP/fakebin" 'GB_REMOTE=fakedrive' 'GB_FOLDER=restic' 'export RESTIC_REPOSITORY="rclone:fakedrive:restic"' "GB_STATE=$TMP/state-rc")
run_ok "GB_FOLDER without a parent folder: skipped with a log line" env GB_CONFIG="$np" "$REPO_DIR/report.sh"
check "...log line + nothing uploaded + no status" all grep -q 'has no parent folder' "$LOGF" --and-- test ! -e "$FAKE/latest-backup-report.txt" -a ! -e "$TMP/state-rc/report-upload.status"
off=$(mkcfg off "GB_BIN=$TMP/fakebin" 'GB_REMOTE=fakedrive' 'GB_FOLDER=GrokBox/restic' 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"' "GB_STATE=$TMP/state-rc" 'DRIVE_REPORT=0')
rm -f "$UP"; run_ok "DRIVE_REPORT=0: written, not uploaded" env GB_CONFIG="$off" "$REPO_DIR/report.sh"
check "...nothing uploaded" test ! -e "$UP" -a -s "$TMP/state-rc/latest-backup-report.txt"
printf 'result=complete\ntime=1e9999\nsnapshot=abc12345\nfiles=08\nbytes=999999999999999999\nadded=-5\nduration_s=1e3\nunreadable=x\n' > "$TMP/state-rc/last-backup.result"
printf 'result=ok\ntime=999999999999999999\npruned=1\n' > "$TMP/state-rc/last-check.result"
printf 'result=ok\ntime=08\nfiles=08\nmismatches=00\n' > "$TMP/state-rc/test-restore.result"
RP2="$TMP/state-rc/latest-backup-report.txt"
run_ok "malformed numbers (1e9999, 18-digit epoch, 08, -5, text) do not break the report" env GB_CONFIG="$off" "$REPO_DIR/report.sh" --no-upload
checkx "...invalid values are 'unknown', leading zeros are plain numbers, no traceback" 'grep -q "^Last backup: *unknown" "$RP2" && grep -q "^Files: *8$" "$RP2" && grep -q "^Source size: *unknown" "$RP2" && grep -q "^Added this run: *unknown" "$RP2" && grep -q "^Last check: *never" "$RP2" && grep -q "8 files, 0 mismatches" "$RP2" && ! grep -q "Traceback" "$TMP/last.out"'
head -c 300 /dev/urandom > "$TMP/state-rc/last-backup.result"
run_ok "a garbled last-backup.result does not break the report" env GB_CONFIG="$off" "$REPO_DIR/report.sh" --no-upload
check "...report still written" grep -q '^Last backup:' "$TMP/state-rc/latest-backup-report.txt"
printf 'result=ok\ntime=%s\nstage=upload\n' "$(now_s)" > "$TMP/state-rc/report-upload.status"
bp=$(mkcfg badpy "GB_BIN=$TMP/fakebin" 'GB_REMOTE=fakedrive' 'GB_FOLDER=GrokBox/restic' 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"' "GB_STATE=$TMP/state-rc" "export PATH=$TMP/badpy:\$PATH")
before=$(cat "$TMP/state-rc/latest-backup-report.txt")
run_ok "report.sh exits 0 when the report cannot be built (python fails)" env GB_CONFIG="$bp" "$REPO_DIR/report.sh"
check "...build failure recorded (result=failed stage=build), previous ok status not kept, old report untouched" all grep -q '^result=failed' "$TMP/state-rc/report-upload.status" --and-- grep -q '^stage=build' "$TMP/state-rc/report-upload.status" --and-- test "$before" = "$(cat "$TMP/state-rc/latest-backup-report.txt")"
GB_CONFIG="$rcl" "$REPO_DIR/status.sh" --local >"$TMP/status.out" 2>&1 || true
GB_CONFIG="$rcl" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "status.sh and doctor.sh show the build failure" all grep -q '!! Drive report: build of latest-backup-report.txt FAILED' "$TMP/status.out" --and-- grep -q '^WARN *drive report: latest-backup-report.txt could not be built' "$TMP/doc.out"
rm -f "$TMP/state-rc/report-upload.status"

step "doctor.sh: PROBLEM / WARN / OK, exit codes, --json, status.sh --doctor, lock ownership, garbled state"
D="$TMP/state-doc"; mkdir -p "$D"; dc=$(mkcfg doc "GB_STATE=$D")
echo $(( $(now_s) - 3 * 3600 )) > "$D/first-start"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "fresh state: exit 2, scheduler NOT running, no backup yet, Overall: PROBLEM" all test "$rc" = 2 --and-- grep -q '^PROBLEM *scheduler: NOT running' "$TMP/doc.out" --and-- grep -q '^PROBLEM *last backup: no complete' "$TMP/doc.out" --and-- grep -q '^Overall: PROBLEM' "$TMP/doc.out"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" --json >"$TMP/doc.json" 2>&1 || rc=$?
check "--json: valid JSON with overall/exit/checks, same exit code" all test "$rc" = 2 --and-- python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["overall"]=="PROBLEM" and d["exit"]==2 and any(c["name"]=="scheduler" and c["status"]=="PROBLEM" for c in d["checks"]) and len(d["checks"])>=10' "$TMP/doc.json"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/status.sh" --doctor --json >"$TMP/doc2.json" 2>&1 || rc=$?
check "status.sh --doctor delegates (same JSON shape and exit code)" all test "$rc" = 2 --and-- python3 -c 'import json,sys;a=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));assert [c["name"] for c in a["checks"]]==[c["name"] for c in b["checks"]]' "$TMP/doc.json" "$TMP/doc2.json"
# healthy: scheduler lock held by a live process, fresh heartbeat, fresh backup/check/test restore/quota sample
( exec 7>>"$D/scheduler.lock"; flock 7; exec sleep 120 ) & SP=$!; sleep 1
now_s > "$D/scheduler.heartbeat"; now_s > "$D/last-success"; now_s > "$D/last-check"; now_s > "$D/last-test-restore"
printf 'drive_pct=20\ndisk_pct=20\ntime=%s\n' "$(now_s)" > "$D/quota.status"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "healthy state: exit 0, Overall: OK, no WARN/PROBLEM lines" all test "$rc" = 0 --and-- grep -q '^Overall: OK' "$TMP/doc.out" --and-- not grep -qE '^(WARN|PROBLEM)' "$TMP/doc.out"
check "one line per topic" bash -c 'for t in alerts scheduler "backup lock" credentials "last backup" "last check" "drive auth" "quota/disk" "test restore" "drive report" "expected bots"; do grep -q "^OK *$t:" "$1" || exit 1; done' _ "$TMP/doc.out"
echo '{"agents":{"tid-2":{}}}' > "$TMP/deleted-agents.json"
dcd=$(mkcfg doc-deleted "GB_STATE=$D" 'EXPECTED_BOTS=("Old Bot")')
rc=0; GB_CONFIG="$dcd" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "deleted bot with stale history: doctor expected bots OK, exit 0" all test "$rc" = 0 --and-- grep -q '^OK       expected bots: no active expected bots; deleted: Old Bot (deleted): history kept (5 messages)' "$TMP/doc.out"
mkdir -p "$TMP/agents/tid-doctor-new"
echo '{"name":"Old Bot"}' > "$TMP/agents/tid-doctor-new/profile.json"
rc=0; GB_CONFIG="$dcd" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "unexported replacement: doctor warns, exit 1" all test "$rc" = 1 --and-- grep -q '^WARN *expected bots: missing from the server-side export: Old Bot (never exported).*; deleted: Old Bot (deleted): history kept (5 messages)' "$TMP/doc.out"
rm -rf "$TMP/agents"
printf 'drive_used=1\ndrive_total=2\ndrive_pct=50\ndisk_pct=85\ndisk_path=/tmp\ntime=%s\n' "$(now_s)" > "$D/quota.status"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "disk 85%: WARN only -> exit 1" all test "$rc" = 1 --and-- grep -q '^WARN *quota/disk: Drive 50% used, local disk 85% used' "$TMP/doc.out" --and-- grep -q '^Overall: WARN' "$TMP/doc.out"
printf 'drive_pct=95\ntime=%s\n' "$(now_s)" > "$D/quota.status"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "Drive 95%: PROBLEM -> exit 2" all test "$rc" = 2 --and-- grep -q '^PROBLEM *quota/disk' "$TMP/doc.out"
rm -f "$D/quota.status"
echo $(( $(now_s) - 3 * 3600 )) > "$D/scheduler.heartbeat"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "stale heartbeat, lock free: PROBLEM scheduler hung" grep -q '^PROBLEM *scheduler: .*has not ticked for 180 min' "$TMP/doc.out"
( exec 7>>"$D/backup.lock"; flock 7; exec sleep 120 ) & LP=$!; sleep 1
echo "$(( $(now_s) - 600 )) $LP backup.sh auto" > "$D/lock-holder"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "stale heartbeat while an UNRELATED job holds the lock: scheduler still PROBLEM, lock OK (held 10 min)" all grep -q '^PROBLEM *scheduler: .*no verified job of its own' "$TMP/doc.out" --and-- grep -q '^OK *backup lock: held by backup.sh (pid '"$LP"')' "$TMP/doc.out"
kill "$LP" "$SP" 2>/dev/null || true; wait "$LP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true
# a fake scheduler: holds scheduler.lock, records its pid, its own child holds backup.lock (parent = scheduler)
cat > "$TMP/fake-scheduler.sh" <<'EOS'
#!/usr/bin/env bash
S="$1"; exec 8>>"$S/scheduler.lock"; flock 8; echo $$ > "$S/scheduler.pid"
( exec 9>>"$S/backup.lock"; flock 9; echo "$(date +%s) $BASHPID backup.sh auto" > "$S/lock-holder"; exec sleep 120 ) 8>&- &
wait
EOS
chmod +x "$TMP/fake-scheduler.sh"; rm -f "$D/lock-holder"
setsid "$TMP/fake-scheduler.sh" "$D" & FS=$!; CHILDREN+=("$FS")
for _ in $(seq 1 50); do [[ -s "$D/lock-holder" ]] && break; sleep .1; done; sleep .2
JP=$(cut -d' ' -f2 "$D/lock-holder")
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "stale heartbeat while the scheduler's OWN verified child holds the lock: scheduler OK, lock OK" all grep -q '^OK *scheduler: .*paused while its own job (backup.sh, pid '"$JP"')' "$TMP/doc.out" --and-- grep -q '^OK *backup lock: held by backup.sh (pid '"$JP"')' "$TMP/doc.out"
now_s > "$D/scheduler.heartbeat"
echo "$(( $(now_s) - 20 * 3600 )) $JP backup.sh auto" > "$D/lock-holder"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "lock held 20h by a live, verified holder: PROBLEM (past the job timeout plus grace)" grep -q '^PROBLEM *backup lock: backup.lock held for 20h by: '"$JP"' backup.sh (past job timeout plus grace)' "$TMP/doc.out"
echo "$(( $(now_s) - 600 )) $$ backup.sh auto" > "$D/lock-holder"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "record names a live pid that does NOT hold the lock (pid reuse): PROBLEM orphan, names the real holder" all grep -q '^PROBLEM *backup lock: backup.lock held.*orphaned/unverifiable record; leftover processes: .*'"$JP"' (sleep)' "$TMP/doc.out" --and-- not grep -q 'a job is running' "$TMP/doc.out"
echo "$(( $(now_s) - 20 * 3600 )) 999999999 check.sh" > "$D/lock-holder"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "lock held, recorded holder pid gone: PROBLEM orphan with the recorded age" grep -q '^PROBLEM *backup lock: backup.lock held for 20h; orphaned/unverifiable record' "$TMP/doc.out"
echo "08 08 x" > "$D/lock-holder"; echo $(( $(now_s) - 3 * 3600 )) > "$D/scheduler.heartbeat"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "garbled lock record + stale heartbeat: PROBLEM orphan, scheduler PROBLEM (not excused), no bash arithmetic error" all test "$rc" = 2 --and-- grep -q '^PROBLEM *backup lock: .*orphaned/unverifiable' "$TMP/doc.out" --and-- grep -q '^PROBLEM *scheduler' "$TMP/doc.out" --and-- not grep -q 'value too great\|syntax error' "$TMP/doc.out"
kill -- "-$FS" 2>/dev/null || true; wait "$FS" 2>/dev/null || true; CHILDREN=(); rm -f "$D/lock-holder" "$D/scheduler.pid"; now_s > "$D/scheduler.heartbeat"
( exec 7>>"$D/scheduler.lock"; flock 7; exec sleep 120 ) & SP=$!; sleep 1
printf 'result=incomplete\ntime=%s\nsnapshot=deadbeef\nfiles=10\nunreadable=2\n' "$(now_s)" > "$D/last-backup.result"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "last-backup.result incomplete after a complete one: WARN with the unreadable count" grep -q '^WARN *last backup: the last run .* ended incomplete (2 unreadable file(s))' "$TMP/doc.out"
printf 'result=complete\ntime=%s\nsnapshot=deadbeef\nfiles=10\n' "$(now_s)" > "$D/last-backup.result"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "last-backup.result complete: OK line names snapshot + files" grep -q '^OK *last backup: complete .*snapshot deadbeef, 10 files' "$TMP/doc.out"
echo $(( $(now_s) - 5 * 3600 )) > "$D/last-success"; printf 'result=complete\ntime=%s\n' "$(( $(now_s) - 5 * 3600 ))" > "$D/last-backup.result"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "last complete backup 5h old (> ALERT_NO_SUCCESS_HOURS): PROBLEM" grep -q '^PROBLEM *last backup: last COMPLETE hourly backup is 5 h old' "$TMP/doc.out"
now_s > "$D/last-success"; rm -f "$D/last-backup.result"
touch "$D/CHECK_FAILED"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "CHECK_FAILED latch: PROBLEM last check" grep -q '^PROBLEM *last check: restic check FAILED (latch' "$TMP/doc.out"
rm -f "$D/CHECK_FAILED"; printf 'result=ok\ntime=%s\npruned=0\n' "$(( $(now_s) - 7200 ))" > "$D/last-check.result"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "last-check.result ok, pruned=0: OK with 'prune skipped'" grep -q '^OK *last check: ok 2 h ago, prune skipped' "$TMP/doc.out"
printf 'result=failed\ntime=%s\nfiles=3\nmismatches=1\n' "$(now_s)" > "$D/test-restore.result"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "test-restore.result failed: PROBLEM" grep -q '^PROBLEM *test restore: FAILED .*1 mismatches' "$TMP/doc.out"
printf 'result=ok\ntime=1e9999\nfiles=08\nmismatches=0\n' > "$D/test-restore.result"; printf 'result=ok\ntime=99999999999999999999\npruned=1\n' > "$D/last-check.result"
printf 'result=complete\ntime=1e9999\nsnapshot=DEADBEEF!\nfiles=99999999999999999999\n' > "$D/last-backup.result"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "time=08 / 1e9999 / 20-digit counts: no arithmetic error, invalid values ignored (test restore + check fall back to the timestamp files)" all test "$rc" -le 2 --and-- not grep -q 'value too great\|syntax error\|Traceback' "$TMP/doc.out" --and-- grep -q '^OK *test restore: ok 0 min ago (8 files verified' "$TMP/doc.out" --and-- grep -q '^OK *last check: ok 0 min ago' "$TMP/doc.out" --and-- grep -q '^OK *last backup: complete 0 min ago' "$TMP/doc.out" --and-- not grep -q 'DEADBEEF' "$TMP/doc.out"
rm -f "$D/test-restore.result" "$D/last-backup.result" "$D/last-check.result"; echo $(( $(now_s) - 12 * 86400 )) > "$D/last-test-restore"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "weekly test restore 12 days old: WARN" grep -q '^WARN *test restore: last OK one is 12 days old (expected weekly)' "$TMP/doc.out"
now_s > "$D/last-test-restore"
echo "alert line" > "$D/ALERT"; touch "$D/PAUSE"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "open alert: PROBLEM; PAUSE: WARN line" all test "$rc" = 2 --and-- grep -q '^PROBLEM *alerts: 1 open' "$TMP/doc.out" --and-- grep -q '^WARN *paused' "$TMP/doc.out"
rm -f "$D/ALERT" "$D/PAUSE"
dcb=$(mkcfg doc-bots "GB_STATE=$D" 'EXPECTED_BOTS=("Test Bot" "Ghost Bot")')
rc=0; GB_CONFIG="$dcb" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "expected bot missing: WARN line, exit 1" all test "$rc" = 1 --and-- grep -q '^WARN *expected bots: missing from the server-side export: Ghost Bot (never exported)' "$TMP/doc.out"
rc=0; GB_CONFIG="$rcl" "$REPO_DIR/doctor.sh" --online >"$TMP/doc.out" 2>&1 || rc=$?
check "rclone repo + token in rclone.conf + --online (fake about ok): drive auth OK" grep -q '^OK *drive auth: token for remote fakedrive present and Drive answers' "$TMP/doc.out"
touch "$FAKE/.fail"; GB_CONFIG="$rcl" "$REPO_DIR/doctor.sh" --online >"$TMP/doc.out" 2>&1 || true; rm -f "$FAKE/.fail"
check "--online with Drive not answering: PROBLEM drive auth" grep -q '^PROBLEM *drive auth: token for remote fakedrive present but Drive does not answer' "$TMP/doc.out"
norc=$(mkcfg norclone "GB_BIN=$TMP/fakebin" 'GB_REMOTE=fakedrive' 'GB_FOLDER=GrokBox/restic' 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"' "GB_STATE=$D" "export RCLONE_CONFIG=$TMP/no-such.conf")
GB_CONFIG="$norc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "rclone.conf missing: PROBLEM drive auth" grep -q '^PROBLEM *drive auth: rclone config missing' "$TMP/doc.out"
for f in last-backup.result last-check.result test-restore.result quota.status report-upload.status lock-holder scheduler.heartbeat; do head -c 200 /dev/urandom > "$D/$f"; done
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "garbled state files: no crash, still prints Overall and a sane exit code ($rc)" all grep -q '^Overall: ' "$TMP/doc.out" --and-- test "$rc" -le 2 --and-- not grep -q 'value too great\|syntax error\|Traceback' "$TMP/doc.out"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" --json >"$TMP/doc.json" 2>&1 || rc=$?
check "garbled state files: --json still valid JSON" python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/doc.json"
rm -f "$D"/{last-backup.result,last-check.result,test-restore.result,quota.status,report-upload.status,lock-holder}
GB_CONFIG="$old" "$REPO_DIR/doctor.sh" --json >"$TMP/doc.json" 2>&1 || true
check "doctor.sh with an older config.env (no new settings) still produces valid JSON" python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["overall"] in ("OK","WARN","PROBLEM")' "$TMP/doc.json"
kill "$SP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true

step "scheduler: weekly test restore slot is due-based and followed by report.sh (waits for the next minute tick)"
SCHED_CFG=$(mkcfg sched 'HOURLY_AT_MIN=60' 'QUICK_EVERY_MIN=0' 'WATCHDOG_AT_MIN=60' 'DAILY_CHECK_AT="23:59"' "TEST_RESTORE_WEEKDAY=$(TZ=UTC date +%w)" 'TEST_RESTORE_AT="00:00"')
echo "2000-01-01" > "$TMP/state/sched-test-restore"; rm -f "$TMP/state/test-restore.result" "$TMP/state/latest-backup-report.txt"
TZ=UTC date +%F > "$TMP/state/sched-check"
t0=$(now_s)
run_ok "install.sh --schedule" env GB_CONFIG="$SCHED_CFG" "$REPO_DIR/install.sh" --schedule
for _ in $(seq 1 100); do [[ -s "$TMP/state/test-restore.result" && -s "$TMP/state/latest-backup-report.txt" ]] && break; sleep 1; done
check "weekly slot due -> test-restore.sh --weekly ran (slot marker = today, result ok)" all test "$(cat "$TMP/state/sched-test-restore")" = "$(TZ=UTC date +%F)" --and-- grep -q '^result=ok' "$TMP/state/test-restore.result"
check "...and report.sh ran after it (took $(( $(now_s) - t0 )) s)" test -s "$TMP/state/latest-backup-report.txt"
check "scheduler log shows the weekly run" grep -q 'test-restore (weekly)' "$LOGF"
GB_CONFIG="$SCHED_CFG" "$REPO_DIR/install.sh" --stop-scheduler >/dev/null 2>&1; SCHED_CFG=""; sleep 1

echo; echo "health tests: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
