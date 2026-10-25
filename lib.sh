#!/usr/bin/env bash
# Shared helpers; source me. Locates the repo from its own path, so the repo can live anywhere.
# Config file: $GB_CONFIG, else <repo>/config.env, else <repo>/config.env.example (defaults).
set -Eeuo pipefail
GB_DIR="${GB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ -z "${GB_CONFIG:-}" ]]; then
  if [[ -f "$GB_DIR/config.env" ]]; then GB_CONFIG="$GB_DIR/config.env"; else GB_CONFIG="$GB_DIR/config.env.example"; fi
fi
[[ -f "$GB_CONFIG" ]] || { echo "config file not found: $GB_CONFIG" >&2; exit 2; }
# shellcheck source=/dev/null
source "$GB_CONFIG"
# defaults for settings added after a config.env was written (older configs keep working)
: "${RESTIC_TIMEOUT:=3h}" "${RESTIC_TIMEOUT_BACKUP:=12h}" "${RESTIC_TIMEOUT_CHECK:=8h}" "${RCLONE_TIMEOUT:=300}"
: "${LOCK_ALERT_HOURS:=13}" "${HEARTBEAT_MAX_MIN:=90}" "${PRUNE_USE_TRASH:=1}"
: "${ALERT_HOOK:=}" "${ALERT_HOOK_TIMEOUT:=60}" "${ALERT_DEDUPE_HOURS:=24}" "${DRIVE_REPORT:=1}"
: "${TEST_RESTORE_AT:=02:20}" "${EXPECTED_BOTS_MAX_HOURS:=26}" "${EXPECTED_BOTS_GRACE_MIN:=60}"
[[ -v TEST_RESTORE_WEEKDAY ]] || TEST_RESTORE_WEEKDAY=0   # unset = Sunday; an explicit "" turns the weekly run off
[[ -v EXPECTED_BOTS ]] || EXPECTED_BOTS=()
export TZ
umask 077   # state, logs, staging and restored scratch data are private by default
mkdir -p "$GB_STATE" "$GB_LOGS" "$GB_STAGING" "$RESTIC_CACHE_DIR"
chmod 700 "$GB_STATE" "$GB_LOGS" "$GB_STAGING" 2>/dev/null || true
LOG="$GB_LOGS/backup-$(date +%Y-%m).log"
ALERTS_LOG="$GB_LOGS/alerts.log"
log()  { echo "[$(date '+%F %T %Z')] $*" | tee -a "$LOG" >&2; }
# alert: loud, persistent failure marker. state/ALERT stays until `status.sh --ack`.
# Dedupe: the same text goes into ALERT/alerts.log and to the hook once per incident; repeats are only noted
# in the month log (state/alert-seen holds "key first-seen count"). The incident key ignores the timestamp and
# every number in the text, so a message whose age, count or pid grows ("held for 13h" -> "14h") stays one
# incident; the first text is the one recorded, every repeat is logged in full. A new incident starts after
# `status.sh --ack` (removes alert-seen) or ALERT_DEDUPE_HOURS after the first occurrence. The decision and
# the state writes happen under state/alert.lock (concurrent callers, --ack); the hook runs after it is released.
alert(){
  local text msg key decision
  text="[$(basename "$0")] $*"
  msg="[$(date '+%F %T %Z')] $text"
  key=$(printf '%s' "$text" | sed 's/[0-9][0-9]*/#/g' | sha256sum | cut -c1-16)
  decision=$(_alert_record "$key" "$msg")
  if [[ "$decision" == repeat* ]]; then log "ALERT ($decision, not re-recorded): $*"; return 0; fi
  log "ALERT: $*"
  alert_hook "$msg"
}
_alert_record(){  # _alert_record KEY MSG -> "new" or "repeat N, same incident since ..."; locked read-modify-write
  local key="$1" msg="$2" seen="$GB_STATE/alert-seen" line first=0 count=1 now
  (
    exec 7>>"$GB_STATE/alert.lock"; flock -w 30 7 || true   # a stuck lock must never lose an alert
    now=$(date +%s)
    line=$(grep -m1 "^$key " "$seen" 2>/dev/null || true)
    [[ -n "$line" ]] && read -r _ first count <<<"$line"
    [[ "$first" =~ ^[0-9]{1,10}$ ]] || first=0; [[ "$count" =~ ^[0-9]{1,10}$ ]] || count=1
    if (( first > 0 && now - first < ${ALERT_DEDUPE_HOURS:-24} * 3600 )); then
      count=$(( 10#$count + 1 ))
      { grep -v "^$key " "$seen" 2>/dev/null; echo "$key $first $count"; } > "$seen.tmp.$$" && mv "$seen.tmp.$$" "$seen"
      echo "repeat $count, same incident since $(date -d "@$first" '+%F %T')"
    else
      { grep -v "^$key " "$seen" 2>/dev/null; echo "$key $now 1"; } > "$seen.tmp.$$" && mv "$seen.tmp.$$" "$seen"
      echo "$msg" >> "$GB_STATE/ALERT"
      echo "$msg" >> "$ALERTS_LOG"
      echo new
    fi
  )
}
# status.sh --ack: acknowledge under the same lock (never interleaves with a concurrent alert()).
alert_ack(){
  (
    exec 7>>"$GB_STATE/alert.lock"; flock -w 30 7 || true
    rm -f "$GB_STATE/alert-seen"   # new incident: repeats of an acknowledged alert are recorded again
    if [[ -s "$GB_STATE/ALERT" ]]; then cat "$GB_STATE/ALERT" >> "$GB_LOGS/alerts-acked.log"; rm -f "$GB_STATE/ALERT"; echo "alerts acknowledged"
    else echo "no alerts"; fi
  )
}
# Optional alert channel (ALERT_HOOK, off by default): the command gets the alert text on stdin and in
# $GB_ALERT_MSG, runs under a timeout, and its failures are logged but never fatal. GB_IN_ALERT_HOOK stops
# a hook that itself raises an alert from running the hook again.
alert_hook(){
  [[ -n "${ALERT_HOOK:-}" && -z "${GB_IN_ALERT_HOOK:-}" ]] || return 0
  local rc=0
  GB_IN_ALERT_HOOK=1 GB_ALERT_MSG="$1" timeout -k 10 "${ALERT_HOOK_TIMEOUT:-60}" bash -c "$ALERT_HOOK" <<<"$1" >>"$GB_LOGS/alert-hook.log" 2>&1 || rc=$?
  (( rc == 0 )) || log "WARN alert hook exited rc=$rc (124 = killed after ALERT_HOOK_TIMEOUT=${ALERT_HOOK_TIMEOUT}s); see $GB_LOGS/alert-hook.log"
  return 0
}
# Small key=value state files shared between the scripts (last-backup.result, test-restore.result, ...).
kv_get() {  # kv_get FILE KEY -> value (empty when the file or the key is missing; never fails; NULs dropped)
  [[ -f "$1" ]] && sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 | tr -d '\000'; return 0; }
kv_write() {  # kv_write FILE key=value... (atomic)
  local f="$1"; shift; printf '%s\n' "$@" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; }
# Numbers from state files are only used after validation: a bounded decimal integer (no sign, no octal
# surprise from leading zeros, no overflow); epochs must also be plausible (< year 2242). Anything else = unknown.
num_ok() { [[ "${1:-}" =~ ^[0-9]{1,15}$ ]] && echo $((10#$1)); return 0; }      # num_ok STR -> plain integer or nothing
epoch_ok() { local v; v=$(num_ok "${1:-}"); [[ -n "$v" ]] && (( v > 0 && v < 8589934592 )) && echo "$v"; return 0; }
kv_num() { num_ok "$(kv_get "$1" "$2")"; }                                    # kv_num FILE KEY
kv_epoch() { epoch_ok "$(kv_get "$1" "$2")"; }                                # kv_epoch FILE KEY
epoch_file() { epoch_ok "$(head -c 32 "$1" 2>/dev/null | tr -d '[:space:]\000')"; }   # epoch_file FILE (one timestamp)
# Weekly test restore: date of the most recent TEST_RESTORE_WEEKDAY (0=Sunday..6) whose TEST_RESTORE_AT
# has passed; prints nothing when TEST_RESTORE_WEEKDAY is empty (weekly run off). scheduler.sh runs
# test-restore.sh --weekly once per slot (due-based, so a slot missed while the box was off is caught up).
test_restore_slot() {
  local wd="${TEST_RESTORE_WEEKDAY:-}" back
  [[ "$wd" =~ ^[0-6]$ ]] || return 0
  back=$(( ( $(date +%w) - wd + 7 ) % 7 ))
  if (( back == 0 )) && [[ "$(date +%H:%M)" < "${TEST_RESTORE_AT:-02:20}" ]]; then back=7; fi
  date -d "-$back days" +%F
}
# Unexpected failures (set -e) also raise an alert, not just a silent non-zero exit.
# shellcheck disable=SC2154
trap 'rc=$?; alert "unexpected failure rc=$rc at line $LINENO: $BASH_COMMAND"' ERR
is_rclone_repo() { [[ "$RESTIC_REPOSITORY" == rclone:* ]]; }
need_creds() {
  [[ -s "$RESTIC_PASSWORD_FILE" ]] || { alert "missing $RESTIC_PASSWORD_FILE (see AGENTS.md: install.sh with RESTIC_BACKUP_PASSWORD set, or --gen-password)"; exit 3; }
  if is_rclone_repo && [[ ! -s "$RCLONE_CONFIG" ]]; then alert "missing $RCLONE_CONFIG (run auth-gdrive.sh)"; exit 3; fi
}
RESTIC_OPTS=(); RESTIC_OPTS_TRASH=()
if is_rclone_repo; then
  RESTIC_OPTS+=(-o "rclone.program=$GB_BIN/rclone" -o "rclone.args=serve restic --stdio $RCLONE_SERVE_ARGS")
  # forget/prune delete repository files. PRUNE_USE_TRASH=1 (default): those deletions go to the Drive trash
  # (recoverable for ~30 days, but they count against the Drive quota until Google empties the trash).
  # PRUNE_USE_TRASH=0: they are deleted at once. The flag is always set explicitly (rclone's own default is "trash").
  _ta="${RCLONE_SERVE_ARGS//--drive-use-trash=false/}"; _ta="${_ta//--drive-use-trash=true/}"
  if [[ "${PRUNE_USE_TRASH:-1}" == 1 ]]; then _ta="$_ta --drive-use-trash=true"; else _ta="$_ta --drive-use-trash=false"; fi
  RESTIC_OPTS_TRASH+=(-o "rclone.program=$GB_BIN/rclone" -o "rclone.args=serve restic --stdio $_ta")
fi
# Every restic call is time-limited (a hung Drive call must not hold backup.lock forever).
# timeout runs restic in its own process group and kills the whole group (restic + its rclone child);
# -k: SIGKILL 60 s after SIGTERM. Override per call: R_TIMEOUT=<duration|0> R ... (0 = no limit).
# Exit code 124 = timed out.
_rt() { local t="${R_TIMEOUT:-${RESTIC_TIMEOUT:-3h}}"
  if [[ "$t" == 0 ]]; then "$@"; else timeout -k 60 "$t" "$@"; fi; }
R()  { _rt "$GB_BIN/restic" "${RESTIC_OPTS[@]}" "$@"; }
RT() { _rt "$GB_BIN/restic" "${RESTIC_OPTS_TRASH[@]}" "$@"; }   # forget/prune (Drive trash)
RCL() { timeout -k 30 "${RCLONE_TIMEOUT:-300}" "$GB_BIN/rclone" --config "$RCLONE_CONFIG" "$@"; }

# Paths that go into a snapshot: the roots, plus each of staging, the config file, state/rebuild-kit
# and (BACKUP_SECRETS=1) the secrets dir that sits outside all roots. Each is checked on its own.
# The password file is always excluded (build_excludes).
under_roots() {  # under_roots PATH ROOT... -> 0 when PATH is a root or inside one
  local s="${1%/}" r p; shift
  for r in "$@"; do p="${r%/}"; if [[ "$s" == "$p" || "$s" == "$p"/* ]]; then return 0; fi; done
  return 1
}
backup_paths() {  # backup_paths ROOT... -> prints the paths, one per line
  local r x
  for r in "$@"; do printf '%s\n' "$r"; done
  for x in "$GB_STAGING" "$GB_CONFIG" "$GB_STATE/rebuild-kit"; do
    if [[ -e "$x" ]] && ! under_roots "$x" "$@"; then printf '%s\n' "${x%/}"; fi
  done
  if [[ "${BACKUP_SECRETS:-0}" == 1 && -d "$GB_SECRETS" ]] && ! under_roots "$GB_SECRETS" "$@"; then printf '%s\n' "${GB_SECRETS%/}"; fi
}

# Combined restic exclude file. Dry runs set EXCL_FILE to a private temp file so they never clobber
# the one a real backup uses.
EXCL_FILE="${EXCL_FILE:-$GB_STATE/excludes.combined}"
# Build the combined restic exclude file: static excludes + generated ones (the repo's own
# secrets/bin/cache, restore dirs, staged live SQLite files) + optional toggles.
build_excludes() {
  local f="$EXCL_FILE" g
  {
    grep -hv '^[[:space:]]*\(#\|$\)' "$GB_DIR/excludes.txt"
    echo "# --- generated"
    echo "$RESTIC_PASSWORD_FILE"            # the repository key is NEVER uploaded
    echo "${GB_SECRETS%/}/restic-pass"
    echo "restic-pass"                      # any file with this name, anywhere
    echo "${RCLONE_CONFIG}.auth.*"             # abandoned private consent workdirs (e.g. after SIGKILL)
    echo "${GB_STATE%/}/auth-*"; echo "${GB_LOGS%/}/auth-*.out"   # one-time OAuth URL/output
    echo "${GB_BIN%/}"; echo "${GB_CACHE%/}"; echo "$RESTIC_CACHE_DIR"
    echo "${GB_STATE%/}/*.lock"; echo "${GB_STATE%/}/excludes.combined"; echo "${GB_STATE%/}/excludes.*.tmp"
    echo "${GB_LOGS%/}/*.tmp"
    echo "${RESTORE_BASE%/}/restore-*"
    if [[ "${BACKUP_SECRETS:-0}" != 1 ]]; then
      echo "${GB_SECRETS%/}"
      grep -hv '^[[:space:]]*\(#\|$\)' "$GB_DIR/excludes-secrets.txt"
    fi
    if [[ "${BACKUP_PROFILE:-full}" == lean ]]; then grep -hv '^[[:space:]]*\(#\|$\)' "$GB_DIR/excludes-lean.txt"; fi
    for g in "${EXTRA_EXCLUDES[@]}"; do echo "$g"; done
    if [[ "${SQLITE_EXCLUDE_LIVE:-1}" == 1 && -s "$GB_STATE/sqlite-staged.txt" ]]; then
      while IFS= read -r g; do echo "$g"; echo "$g-wal"; echo "$g-shm"; echo "$g-journal"; done < "$GB_STATE/sqlite-staged.txt"
    fi
  } > "$f.tmp"
  mv "$f.tmp" "$f"
}
exclude_args() {
  build_excludes
  EXARGS=(--exclude-file "$EXCL_FILE")
  [[ "${EXCLUDE_VENVS:-0}" == 1 ]] && EXARGS+=(--exclude-if-present pyvenv.cfg)
  [[ "${EXCLUDE_CACHEDIRS:-0}" == 1 ]] && EXARGS+=(--exclude-caches)
  return 0
}
manifest() {  # manifest PATH... -> JSON on stdout (same excludes as restic, approximately)
  build_excludes
  python3 "$GB_DIR/manifest.py" --exclude-file "$EXCL_FILE" \
    --venvs "$EXCLUDE_VENVS" --cachedirs "$EXCLUDE_CACHEDIRS" \
    --ignore-newest "$GB_DIR" --ignore-newest "$GB_STAGING" --ignore-newest "$GB_STATE" --ignore-newest "$GB_LOGS" "$@"
}
box_ready() {  # 0 when the box finished booting/hydrating files; logs why not
  local up_min=$(( $(cut -d. -f1 /proc/uptime) / 60 ))
  if (( up_min < GUARD_MIN_UPTIME_MIN )); then log "uptime ${up_min}m < ${GUARD_MIN_UPTIME_MIN}m; box may still be restoring files; skip"; return 1; fi
  if [[ -n "${HYDRATION_LOG:-}" && -f "$HYDRATION_LOG" ]] && ! grep -q -- "${HYDRATION_OK_PATTERN:-}" "$HYDRATION_LOG"; then
    log "box file hydration not finished ($HYDRATION_LOG lacks '${HYDRATION_OK_PATTERN:-}'); skip"; return 1; fi
  return 0
}
# Scheduler detection: the loop holds an flock on state/scheduler.lock for its whole life.
sched_running() { ! ( exec 7>>"$GB_STATE/scheduler.lock"; flock -n 7 ); }
sched_pid() {  # pid of the running scheduler loop (empty if none)
  local p; p=$(cat "$GB_STATE/scheduler.pid" 2>/dev/null || true)
  if [[ -n "$p" ]] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'scheduler\.sh'; then echo "$p"; fi
  return 0
}
# Who holds backup.lock since when (for the "lock held too long" alert). Written right after flock.
took_lock() { echo "$(date +%s) $$ $(basename "$0") $*" > "$GB_STATE/lock-holder"; }
lock_busy() { ! ( exec 7>>"$GB_STATE/backup.lock"; flock -n 7 ); }
lock_record() {
  local rest
  LOCK_TIME=""; LOCK_PID=""; LOCK_JOB=""
  read -r LOCK_TIME LOCK_PID LOCK_JOB rest < "$GB_STATE/lock-holder" 2>/dev/null || return 1
  [[ "$LOCK_TIME" =~ ^[0-9]{1,10}$ && "$LOCK_PID" =~ ^[0-9]+$ ]] || return 1
  LOCK_TIME=$((10#$LOCK_TIME))
  (( LOCK_TIME <= $(date +%s) ))
}
lock_holder_alive() { python3 "$GB_DIR/lock-control.py" holds "$GB_STATE/backup.lock" "$LOCK_PID"; }
lock_age_h() {  # retain the timestamp even when an inherited fd outlives the recorded parent
  lock_busy && lock_record || return 0
  echo $(( ( $(date +%s) - LOCK_TIME ) / 3600 ))
}
lock_budget_s() {
  local duration="$RESTIC_TIMEOUT_BACKUP" factor=1
  # check can run unlock, two forget calls, check, prune and test restore in sequence.
  [[ "$LOCK_JOB" == check.sh ]] && { duration="$RESTIC_TIMEOUT_CHECK"; factor=3; }
  python3 - "$duration" "$factor" "$LOCK_ALERT_HOURS" <<'PYLOCK'
import re,sys
m=re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smhd]?)",sys.argv[1])
n=float(m[1])*{'':1,'s':1,'m':60,'h':3600,'d':86400}[m[2]] if m else 0
print(int(max(float(sys.argv[3])*3600, n*int(sys.argv[2])+3600)))
PYLOCK
}
lock_problem() {
  lock_busy || return 0
  local valid=0 age
  lock_record && lock_holder_alive && valid=1
  if [[ $valid == 0 ]]; then
    sleep 2  # flock acquired -> record written is not atomic
    lock_busy || return 0
    if ! lock_record || ! lock_holder_alive; then
      age=$(lock_age_h)
      echo "backup.lock held${age:+ for ${age}h}; orphaned/unverifiable record; leftover processes: $(python3 "$GB_DIR/lock-control.py" holders "$GB_STATE/backup.lock" | paste -sd ','); inspect before an explicit --restart-scheduler --force"
      return 0
    fi
  fi
  if (( $(date +%s) - LOCK_TIME >= $(lock_budget_s) )); then
    echo "backup.lock held for $(lock_age_h)h by: $LOCK_PID $LOCK_JOB (past job timeout plus grace)"
  fi
}
heartbeat_job_active() {
  # Only the scheduler's own verified child can explain a stale heartbeat.
  local scheduler parent
  lock_busy && lock_record && lock_holder_alive || return 1
  scheduler=$(sched_pid); [[ -n "$scheduler" ]] || return 1
  parent=$(ps -o ppid= -p "$LOCK_PID" | tr -d ' ')
  [[ "$parent" == "$scheduler" ]] && (( LOCK_TIME >= ${1:-0} && $(date +%s) - LOCK_TIME < $(lock_budget_s) ))
}
# First start of install/scheduler on this box: reference for the "no successful backup yet" alerts.
mark_first_start() { [[ -s "$GB_STATE/first-start" ]] || date +%s > "$GB_STATE/first-start"; }
# Stale-guard latch: set when the guard trips, cleared only by a successful hourly backup. While it
# exists nothing may forget/prune snapshots.
# shellcheck disable=SC2034  # used by the scripts that source this file
GUARD_LATCH="$GB_STATE/GUARD_TRIPPED"
# SQLite latch: set when staging consistent DB copies failed; blocks forget/prune until a fully
# successful hourly backup (live DB files may have been backed up mid-write meanwhile).
# shellcheck disable=SC2034
SQLITE_LATCH="$GB_STATE/SQLITE_FAILED"

# Older releases left auto/quick on incomplete snapshots. Remove those retention tags first.
prepare_retention() {
  local ids id
  ids=$(R snapshots --host "$BACKUP_HOST" --tag incomplete --json | python3 -c 'import json,sys;print("\n".join(s["id"] for s in json.load(sys.stdin) if set(s.get("tags") or []) & {"auto","quick"}))') || return 1
  while IFS= read -r id; do
    [[ -z "$id" ]] || R tag --remove auto,quick "$id" >>"$LOG" 2>&1 || return 1
  done <<< "$ids"
}

backup_result_status() {
  python3 - "$GB_STATE/last-backup.result" <<'PYRESULT'
import re,sys
try:
    lines=open(sys.argv[1]).read().splitlines()
    d=dict(line.split('=',1) for line in lines)
    assert len(d)==len(lines)
    assert d['result'] in ('complete','incomplete','failed','timeout')
    for key in ('time','files','bytes','added','duration_s','unreadable'):
        assert re.fullmatch(r'[0-9]+',d[key])
    assert re.fullmatch(r'[0-9a-f]{0,64}',d['snapshot'])
    assert d['result']!='complete' or d['snapshot']
    print(d['result'])
except (OSError, ValueError, KeyError, AssertionError):
    print('unknown')
PYRESULT
}
