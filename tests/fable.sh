#!/usr/bin/env bash
# Offline tests for doctor.sh, the weekly test restore, alert dedupe + ALERT_HOOK, the expected-bot roster and
# the Drive report (report.sh). Needs NO Google Drive: local restic repository + a fake rclone in a temp dir.
#   tests/fable.sh            run        KEEP_TMP=1 tests/fable.sh   keep the temp directory
# shellcheck disable=SC2016,SC2034  # single-quoted `bash -c` / checkx snippets expand later on purpose
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grokbox-fable.XXXXXX")"
[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] || { echo "refusing: temp dir $TMP is not under /tmp"; exit 1; }
SCHED_CFG=""
cleanup() { [[ -n "$SCHED_CFG" ]] && GB_CONFIG="$SCHED_CFG" "$REPO_DIR/install.sh" --stop-scheduler >/dev/null 2>&1 || true
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
mkdir -p "$SRC/docs" "$SRC/agent-data/memory" "$SEC" "$SE/state" "$TMP/fakebin" "$FAKE"; chmod 700 "$SEC"
python3 - "$SRC" <<'PY'
import os, random, sys
src = sys.argv[1]; random.seed(11)
for i in range(12):
    with open(f"{src}/docs/f{i:02d}.bin", "wb") as f: f.write(random.randbytes(5000 + i))
open(f"{src}/agent-data/memory/notes.md", "w").write("remember: fable test\n")
open(f"{src}/agent-data/critical.txt", "w").write("critical file content 0123456789\n")
PY
printf 'fable-test-password-%s' "$RANDOM" > "$SEC/restic-pass"; chmod 600 "$SEC/restic-pass"
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
cat > "$TMP/config.env" <<CFG
GB_BIN="$REPO_DIR/bin"
GB_SECRETS="$SEC"
GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export RESTIC_REPOSITORY="$REPO"
export SERVER_EXPORT_DIR="$SE"
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
# server-export fixture: three bots (fresh, stale, unreadable)
python3 - "$SE/state/positions.json" <<'PY'
import json, sys, time
f = lambda t: time.strftime('%Y-%m-%d %H:%M:%S%z', time.localtime(t))
now = time.time()
json.dump({"tid-1": {"name": "Test Bot", "total": 10, "max_pos": 9, "lines": 10, "checked": f(now), "last_export": f(now)},
           "tid-2": {"name": "Old Bot", "total": 5, "max_pos": 4, "lines": 5, "checked": f(now - 40 * 3600)},
           "tid-3": {"name": "Hidden Bot", "total": 0, "unreadable": True, "checked": f(now)}}, open(sys.argv[1], "w"), indent=1)
PY
echo "# index" > "$SE/INDEX.md"; chmod -R go-rwx "$SE"
alert_in() { local c="$1"; shift; GB_CONFIG="$c" bash -c 'source "$1/lib.sh"; shift; alert "$@"' _ "$REPO_DIR" "$@"; }

step "lib.sh: kv helpers, weekly slot"
run_ok "lib.sh sources with the example defaults (new settings get defaults)" bash -c 'source "$1/lib.sh"; [[ "$ALERT_DEDUPE_HOURS" == 24 && "$TEST_RESTORE_WEEKDAY" == 0 && "$DRIVE_REPORT" == 1 && ${#EXPECTED_BOTS[@]} == 0 ]]' _ "$REPO_DIR"
old=$(mkcfg old 'unset ALERT_HOOK ALERT_HOOK_TIMEOUT ALERT_DEDUPE_HOURS DRIVE_REPORT TEST_RESTORE_WEEKDAY TEST_RESTORE_AT EXPECTED_BOTS EXPECTED_BOTS_MAX_HOURS')
run_ok "an older config.env without the new settings still sources (defaults filled in)" env GB_CONFIG="$old" bash -c 'source "$1/lib.sh"; [[ "$ALERT_DEDUPE_HOURS" == 24 && ${#EXPECTED_BOTS[@]} == 0 ]]' _ "$REPO_DIR"
v=$(bash -c 'source "$1/lib.sh"; kv_write "$GB_STATE/kv.test" "result=ok" "time=42" "note=a=b"; kv_get "$GB_STATE/kv.test" note; kv_get "$GB_STATE/kv.test" missing; kv_get "$GB_STATE/nofile" x; echo end' _ "$REPO_DIR")
check "kv_write/kv_get round trip; missing key/file give empty, never fail" test "$v" = "a=b
end"
# the config sets TZ=UTC, so the expected dates are computed in UTC too
wd=$(TZ=UTC date +%w); wdn=$(( (wd + 1) % 7 ))
slot() { GB_CONFIG="$(mkcfg "slot$1" "TEST_RESTORE_WEEKDAY=$2" "TEST_RESTORE_AT=$3")" bash -c 'source "$1/lib.sh"; test_restore_slot' _ "$REPO_DIR"; }
check "weekly slot: today's weekday after TEST_RESTORE_AT -> today" test "$(slot 1 "$wd" 00:00)" = "$(TZ=UTC date +%F)"
check "weekly slot: today's weekday before TEST_RESTORE_AT -> a week ago" test "$(slot 2 "$wd" 23:59)" = "$(TZ=UTC date -d '-7 days' +%F)"
check "weekly slot: tomorrow's weekday -> 6 days ago" test "$(slot 3 "$wdn" 00:00)" = "$(TZ=UTC date -d '-6 days' +%F)"
check "weekly slot: empty TEST_RESTORE_WEEKDAY -> off (prints nothing)" test -z "$(slot 4 '""' 00:00)"

step "alert dedupe (once per incident) + status.sh --ack starts a new incident"
alert_in "$GB_CONFIG" "dup test message"; alert_in "$GB_CONFIG" "dup test message"; alert_in "$GB_CONFIG" "another message"
check "two identical alerts + one other -> 2 lines in state/ALERT" test "$(wc -l < "$TMP/state/ALERT")" = 2
check "...and 2 lines in logs/alerts.log" test "$(grep -c 'test message\|another message' "$TMP/logs/alerts.log")" = 2
check "the repeat is noted in the month log" grep -q 'ALERT (repeat 2' "$LOGF"
check "state/alert-seen records the incident with count 2" grep -q ' 2$' "$TMP/state/alert-seen"
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1
check "--ack removes state/alert-seen" test ! -e "$TMP/state/alert-seen"
alert_in "$GB_CONFIG" "dup test message"
check "after --ack the same text is recorded again (new incident)" test "$(wc -l < "$TMP/state/ALERT")" = 1
python3 - "$TMP/state/alert-seen" <<'PY'
import sys,time
p=sys.argv[1]; k,t,c=open(p).read().split()
open(p,"w").write(f"{k} {int(time.time())-25*3600} {c}\n")
PY
alert_in "$GB_CONFIG" "dup test message"
check "after ALERT_DEDUPE_HOURS the same text is recorded again" test "$(wc -l < "$TMP/state/ALERT")" = 2
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
alert_in "$TMP/config-recurse.env" "outer alert"
checkx "a hook that raises an alert does not run the hook again (ran once, both alerts recorded)" 'test "$(grep -c "^ran$" "$TMP/hook.out")" = 1 && grep -q "raised from inside the hook" "$TMP/state/ALERT" && grep -q "outer alert" "$TMP/state/ALERT"'
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "expected-bot roster (expected-bots.sh)"
rc=0; out=$("$REPO_DIR/expected-bots.sh") || rc=$?
checkx "empty roster: 'no roster configured', exit 0" 'test "$rc" = 0 && grep -q "no roster" <<<"$out"'
eb=$(mkcfg bots 'EXPECTED_BOTS=("test bot" "tid-2" "Hidden Bot" "Ghost Bot")')
rc=0; out=$(GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "missing bots -> exit 1, listing why" 'test "$rc" = 1 && [[ "$out" == *"Ghost Bot (never exported)"* && "$out" == *"Hidden Bot (not readable)"* && "$out" == *"tid-2 (last export check 40 h ago)"* && "$out" == *"present: 1 of 4"* ]]'
GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true; GB_CONFIG="$eb" "$REPO_DIR/expected-bots.sh" --alert >/dev/null || true
check "--alert raises one deduped alert" test "$(grep -c 'expected bots missing' "$TMP/state/ALERT")" = 1
ok1=$(mkcfg bots-ok 'EXPECTED_BOTS=("Test Bot")')
rc=0; out=$(GB_CONFIG="$ok1" "$REPO_DIR/expected-bots.sh") || rc=$?
checkx "name match (case-insensitive / slug) -> all present, exit 0" 'test "$rc" = 0 && grep -q "all 1 expected bots present" <<<"$out"'
nox=$(mkcfg bots-noexport 'EXPECTED_BOTS=("Test Bot")' "export SERVER_EXPORT_DIR=$TMP/nowhere")
rc=0; out=$(GB_CONFIG="$nox" "$REPO_DIR/expected-bots.sh" --alert) || rc=$?
checkx "no export yet -> exit 2, no alert" 'test "$rc" = 2 && grep -q "no server-side export yet" <<<"$out" && test "$(grep -c "expected bots" "$TMP/state/ALERT")" = 1'
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "backup + weekly test restore (critical files, sha256 compare, result file, lock)"
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
kill "$LP" 2>/dev/null || true; wait "$LP" 2>/dev/null || true
"$REPO_DIR/status.sh" --ack >/dev/null 2>&1

step "report.sh: local report, Drive upload via fake rclone, failure visibility"
run_ok "report.sh (local repository: written, not uploaded)" "$REPO_DIR/report.sh"
RP="$TMP/state/latest-backup-report.txt"
check "report written" test -s "$RP"
checkx "report: result complete (from last-success), files from the snapshot summary, failed test restore shown" 'grep -q "^Result: *complete" "$RP" && grep -qE "^Files: *[0-9,]+$" "$RP" && grep -q "Last test restore:.*failed" "$RP"'
check "report holds no paths or secrets" not grep -qF -e "$TMP" -e "/home/" -e "$(cat "$SEC/restic-pass")" "$RP"
check "log says locally only" grep -q 'not an rclone: repository' "$LOGF"
check "no upload status for a local repository" test ! -e "$TMP/state/report-upload.status"
rcl=$(mkcfg rclone "GB_BIN=$TMP/fakebin" 'GB_REMOTE=fakedrive' 'GB_FOLDER=GrokBox/restic' 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"' "GB_STATE=$TMP/state-rc")
mkdir -p "$TMP/state-rc"
printf 'result=complete\ntime=%s\nsnapshot=abc12345\nfiles=4321\nbytes=123456789\nadded=1048576\nduration_s=125\nunreadable=0\n' "$(now_s)" > "$TMP/state-rc/last-backup.result"
printf 'result=ok\ntime=%s\npruned=1\n' "$(( $(now_s) - 3600 ))" > "$TMP/state-rc/last-check.result"
printf 'result=ok\ntime=%s\nfiles=25\nmismatches=0\n' "$(( $(now_s) - 86400 ))" > "$TMP/state-rc/test-restore.result"
run_ok "report.sh with an rclone: repository (fake rclone)" env GB_CONFIG="$rcl" "$REPO_DIR/report.sh"
UP="$FAKE/GrokBox/latest-backup-report.txt"
check "uploaded into the PARENT of GB_FOLDER, not into restic/" test -s "$UP" -a ! -e "$FAKE/GrokBox/restic/latest-backup-report.txt"
check "uploaded file equals the local report" cmp -s "$UP" "$TMP/state-rc/latest-backup-report.txt"
check "report uses last-backup.result: files 4,321; snapshot; 2 min 5 s; added 1.0 MB; prune yes; test restore 25 files" bash -c 'grep -q "4,321" "$1" && grep -q abc12345 "$1" && grep -q "2 min 5 s" "$1" && grep -q "1.0 MB" "$1" && grep -q "prune: yes" "$1" && grep -q "25 files, 0 mismatches" "$1"' _ "$UP"
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
head -c 300 /dev/urandom > "$TMP/state-rc/last-backup.result"
run_ok "a garbled last-backup.result does not break the report" env GB_CONFIG="$off" "$REPO_DIR/report.sh" --no-upload
check "...report still written" grep -q '^Last backup:' "$TMP/state-rc/latest-backup-report.txt"

step "doctor.sh: PROBLEM / WARN / OK, exit codes, --json, status.sh --doctor, garbled state"
D="$TMP/state-doc"; mkdir -p "$D"; dc=$(mkcfg doc "GB_STATE=$D")
echo $(( $(now_s) - 3 * 3600 )) > "$D/first-start"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "fresh state: exit 2, scheduler NOT running, no backup yet, Overall: PROBLEM" all test "$rc" = 2 --and-- grep -q '^PROBLEM *scheduler: NOT running' "$TMP/doc.out" --and-- grep -q '^PROBLEM *last backup: no complete' "$TMP/doc.out" --and-- grep -q '^Overall: PROBLEM' "$TMP/doc.out"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" --json >"$TMP/doc.json" 2>&1 || rc=$?
check "--json: valid JSON with overall/exit/checks, same exit code" all test "$rc" = 2 --and-- python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));assert d["overall"]=="PROBLEM" and d["exit"]==2 and any(c["name"]=="scheduler" and c["status"]=="PROBLEM" for c in d["checks"]) and len(d["checks"])>=10' "$TMP/doc.json"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/status.sh" --doctor --json >"$TMP/doc2.json" 2>&1 || rc=$?
check "status.sh --doctor delegates (same JSON shape and exit code)" all test "$rc" = 2 --and-- python3 -c 'import json,sys;a=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));assert [c["name"] for c in a["checks"]]==[c["name"] for c in b["checks"]]' "$TMP/doc.json" "$TMP/doc2.json"
# healthy: scheduler lock held by a live process, fresh heartbeat, fresh backup/check/test restore
( exec 7>>"$D/scheduler.lock"; flock 7; exec sleep 120 ) & SP=$!; sleep 1
now_s > "$D/scheduler.heartbeat"; now_s > "$D/last-success"; now_s > "$D/last-check"; now_s > "$D/last-test-restore"
rc=0; GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || rc=$?
check "healthy state: exit 0, Overall: OK, no WARN/PROBLEM lines" all test "$rc" = 0 --and-- grep -q '^Overall: OK' "$TMP/doc.out" --and-- not grep -qE '^(WARN|PROBLEM)' "$TMP/doc.out"
check "one line per topic" bash -c 'for t in alerts scheduler "backup lock" credentials "last backup" "last check" "drive auth" "quota/disk" "test restore" "drive report" "expected bots"; do grep -q "^OK *$t:" "$1" || exit 1; done' _ "$TMP/doc.out"
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
check "stale heartbeat while a job holds the lock: scheduler OK, lock OK (held 10 min by backup.sh auto)" all grep -q '^OK *scheduler: .*paused while its job' "$TMP/doc.out" --and-- grep -q '^OK *backup lock: held by backup.sh auto (pid '"$LP"')' "$TMP/doc.out"
now_s > "$D/scheduler.heartbeat"
echo "$(( $(now_s) - 20 * 3600 )) $LP backup.sh auto" > "$D/lock-holder"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "lock held 20h by a live pid: PROBLEM" grep -q '^PROBLEM *backup lock: held by backup.sh auto (pid '"$LP"') for 20 h' "$TMP/doc.out"
echo "$(( $(now_s) - 20 * 3600 )) 999999999 check.sh" > "$D/lock-holder"
GB_CONFIG="$dc" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "lock held, recorded holder pid gone: WARN" grep -q '^WARN *backup lock: held, but the recorded holder check.sh (pid 999999999) is gone' "$TMP/doc.out"
kill "$LP" 2>/dev/null || true; wait "$LP" 2>/dev/null || true; rm -f "$D/lock-holder"
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
rm -f "$D/test-restore.result"; echo $(( $(now_s) - 12 * 86400 )) > "$D/last-test-restore"
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
check "garbled state files: no crash, still prints Overall and a sane exit code ($rc)" all grep -q '^Overall: ' "$TMP/doc.out" --and-- test "$rc" -le 2
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
python3 - "$SRC/agent-data/critical.txt" <<'PY'
import os,sys
p=sys.argv[1]; st=os.stat(p); d=open(p,"rb").read(); open(p,"wb").write(b"c"+d[1:]); os.utime(p,(st.st_atime,st.st_mtime))
PY
t0=$(now_s)
run_ok "install.sh --schedule" env GB_CONFIG="$SCHED_CFG" "$REPO_DIR/install.sh" --schedule
for _ in $(seq 1 100); do [[ -s "$TMP/state/test-restore.result" && -s "$TMP/state/latest-backup-report.txt" ]] && break; sleep 1; done
check "weekly slot due -> test-restore.sh --weekly ran (slot marker = today, result ok)" all test "$(cat "$TMP/state/sched-test-restore")" = "$(TZ=UTC date +%F)" --and-- grep -q '^result=ok' "$TMP/state/test-restore.result"
check "...and report.sh ran after it (took $(( $(now_s) - t0 )) s)" test -s "$TMP/state/latest-backup-report.txt"
check "scheduler log shows the weekly run" grep -q 'test-restore (weekly)' "$LOGF"
GB_CONFIG="$SCHED_CFG" "$REPO_DIR/install.sh" --stop-scheduler >/dev/null 2>&1; SCHED_CFG=""; sleep 1

echo; echo "fable tests: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
