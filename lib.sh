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
: "${RESTIC_TIMEOUT_META:=10m}" "${RESTIC_TIMEOUT_FORGET:=30m}"
# An explicitly empty value disables the transport defaults.
: "${RCLONE_NET_ARGS=--contimeout 30s --timeout 2m --low-level-retries 5}"
: "${LOCK_ALERT_HOURS:=13}" "${HEARTBEAT_MAX_MIN:=90}" "${PRUNE_USE_TRASH:=1}"
: "${QUOTA_ALERT_PCT:=90}" "${LOG_RETENTION_DAYS:=0}" "${RESTORE_LOCK_WAIT:=600}"
: "${ALERT_HOOK:=}" "${ALERT_HOOK_TIMEOUT:=60}" "${ALERT_DEDUPE_HOURS:=24}" "${DRIVE_REPORT:=1}"
: "${ALERT_NTFY_URL:=}" "${ALERT_WEBHOOK_URL:=}" "${ALERT_CHANNEL_REQUIRED:=1}"
: "${EXPORT_MISSED_HOURS:=26}"
: "${EXPECTED_BOTS_REQUIRED:=1}"
: "${PROMOTE_LOCK_WAIT:=2m}" "${SNAPSHOT_LIST_RETRY_S:=5}"
: "${LOCK_RETRY_WAIT:=2m}"
: "${PRUNE_SKIP_PROBLEM_DAYS:=3}" "${HOURLY_MISS_WARN:=1}" "${HOURLY_SLOT_WINDOW_H:=24}"
GB_UNLOCK_DONE=0
: "${TEST_RESTORE_AT:=02:20}" "${EXPECTED_BOTS_MAX_HOURS:=26}" "${EXPECTED_BOTS_GRACE_MIN:=60}"
[[ -v TEST_RESTORE_WEEKDAY ]] || TEST_RESTORE_WEEKDAY=0   # unset = Sunday; an explicit "" turns the weekly run off
if [[ "$TEST_RESTORE_WEEKDAY" =~ ^[0-6]$ ]]; then : "${TEST_RESTORE_MAX_DAYS:=10}"
else : "${TEST_RESTORE_MAX_DAYS:=35}"; fi
: "${TEST_RESTORE_FIRST_DAYS:=3}"
[[ -v EXPECTED_BOTS ]] || EXPECTED_BOTS=()
: "${AGENTS_DIR=/home/box/agent-data/agents}"
export AGENTS_DIR
: "${DELETED_BOTS_FILE=/home/box/agent-data/deleted-agents.json}"
export DELETED_BOTS_FILE
[[ -v RETIRED_BOTS ]] || RETIRED_BOTS=()
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
# standalone numbers, so a message whose age, count or pid grows ("held for 13h" -> "14h") stays one
# incident; the first text is the one recorded, every repeat is logged in full. A new incident starts after
# `status.sh --ack` (removes alert-seen) or ALERT_DEDUPE_HOURS after the first occurrence. The decision and
# the state writes happen under state/alert.lock (concurrent callers, --ack); the hook runs after it is released.
alert(){
  local text msg key decision
  text="[$(basename "$0")] $*"
  msg="[$(date '+%F %T %Z')] $text"
  key=$(printf '%s' "$text" | _alert_normalize | sha256sum | cut -c1-16)
  decision=$(_alert_record "$key" "$msg")
  if [[ "$decision" == repeat* ]]; then log "ALERT ($decision, not re-recorded): $*"; return 0; fi
  log "ALERT: $*"
  alert_hook "$msg"
}
# Keep digits in identifiers (bot-10, Name2, v2); mask dates and standalone measurements.
# Repeat the token substitution because adjacent numbers can share a delimiter.
_alert_normalize(){
  local stamp='(^|[^[:alnum:]_.-])[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?($|[^[:alnum:]_.-]|[.]([[:space:]]|$))'
  local token='(^|[^[:alnum:]_.-])[0-9]+([.][0-9]+)?(h|m|min|s|d|ms|%|days|hours|minutes|seconds|files|bytes|[kKmMgGtT]i?[bB])?($|[^[:alnum:]_.-]|[.]([[:space:]]|$))'
  sed -E -e "s/$stamp/\1#\5/g" -e "s/$stamp/\1#\5/g" \
    -e "s/$token/\1#\3\4/g" -e "s/$token/\1#\3\4/g"
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
# Channel names only: safe for status files and diagnostics.
alert_channels(){
  local names=""
  [[ -n "$ALERT_NTFY_URL" ]] && names=ntfy
  [[ -n "$ALERT_WEBHOOK_URL" ]] && names+="${names:++}webhook"
  [[ -n "$ALERT_HOOK" ]] && names+="${names:++}hook"
  printf '%s' "$names"
}
# URLs travel only over stdin, quoted for curl's config parser (including embedded newlines).
_alert_curl_config(){
  local url="$1"
  url=${url//\\/\\\\}; url=${url//\"/\\\"}
  url=${url//$'\n'/\\n}; url=${url//$'\r'/\\r}; url=${url//$'\t'/\\t}; url=${url//$'\v'/\\v}
  printf 'url = "%s"\n' "$url"
}
# One synchronous send; returns this channel's rc. Curl output can contain a secret URL, so discard it.
alert_send(){
  local channel="$1" msg="$2" rc=0 body url content_type
  if [[ "$channel" == hook ]]; then
    GB_IN_ALERT_HOOK=1 GB_ALERT_MSG="$msg" timeout -k 10 "${ALERT_HOOK_TIMEOUT:-60}" bash -c "$ALERT_HOOK" <<<"$msg" >>"$GB_LOGS/alert-hook.log" 2>&1 || rc=$?
    return "$rc"
  fi
  body=$(mktemp /tmp/grokbox-alert.XXXXXX) || return 1
  if [[ "$channel" == ntfy ]]; then
    url=$ALERT_NTFY_URL; content_type=text/plain
    printf '%s' "$msg" > "$body" || rc=$?
  else
    url=$ALERT_WEBHOOK_URL; content_type=application/json
    printf '%s' "$msg" | python3 -c 'import json,sys; json.dump({"text": sys.stdin.read()}, sys.stdout)' > "$body" 2>/dev/null || rc=$?
  fi
  if (( rc == 0 )); then
    _alert_curl_config "$url" | GB_IN_ALERT_HOOK=1 curl --disable --fail --silent --show-error --max-time "$ALERT_HOOK_TIMEOUT" \
      -K - --request POST --header "Content-Type: $content_type" --data-binary "@$body" >/dev/null 2>&1 || rc=$?
  fi
  rm -f "$body"
  return "$rc"
}
# Shared by real alerts and test-alert.sh. A hook raising an alert must not send recursively.
alert_deliver(){
  [[ -z "${GB_IN_ALERT_HOOK:-}" ]] || return 0
  local msg="$1" mode="${2:-real}" names channel rc result=ok failed=0 attempted=""
  local channels=()
  names=$(alert_channels)
  [[ -n "$names" ]] || return 3
  IFS=+ read -r -a channels <<<"$names"
  for channel in "${channels[@]}"; do
    rc=0; alert_send "$channel" "$msg" || rc=$?
    if (( rc != 0 )); then
      result=failed; failed=1
      printf '%s: FAILED (rc=%s)\n' "$channel" "$rc" >>"$GB_LOGS/alert-hook.log"
      if [[ "$channel" == hook ]]; then
        log "WARN alert hook exited rc=$rc (124 = killed after ALERT_HOOK_TIMEOUT=${ALERT_HOOK_TIMEOUT}s); see $GB_LOGS/alert-hook.log"
      else log "WARN alert $channel exited rc=$rc (timeout=${ALERT_HOOK_TIMEOUT}s); see $GB_LOGS/alert-hook.log"; fi
    fi
    if [[ "$mode" == test ]]; then
      if (( rc == 0 )); then echo "$channel: ok"; else echo "$channel: FAILED (rc=$rc)"; fi
    else
      attempted+="${attempted:++}$channel"
      kv_write "$GB_STATE/alert-delivery.status" "result=$result" "time=$(date +%s)" "channels=$attempted"
    fi
  done
  if [[ "$mode" == test ]]; then
    kv_write "$GB_STATE/alert-test.status" "result=$result" "time=$(date +%s)"
  fi
  return "$failed"
}
# Real delivery failures never fail the job that raised the alert.
alert_hook(){
  alert_deliver "$1" || true
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
# Diagnostics share the same validated lock-skip record and quick-chain age limit.
skipped_backup() {
  local success
  SKIP_TIME=$(kv_epoch "$GB_STATE/backup-skipped" time)
  SKIP_HOLDER=$(kv_get "$GB_STATE/backup-skipped" holder)
  [[ "$SKIP_HOLDER" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || SKIP_HOLDER=unknown
  success=$(epoch_file "$GB_STATE/last-success")
  [[ -n "$SKIP_TIME" ]] && (( SKIP_TIME > ${success:-0} ))
}
quick_max_age_s() {
  local minutes
  minutes=$(num_ok "$QUICK_EVERY_MIN"); minutes=${minutes:-15}
  if (( minutes > 40 )); then echo "$(( minutes * 180 ))"; else echo 7200; fi
}
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
  RESTIC_OPTS+=(-o "rclone.program=$GB_BIN/rclone" -o "rclone.args=serve restic --stdio $RCLONE_NET_ARGS $RCLONE_SERVE_ARGS")
  # forget/prune delete repository files. PRUNE_USE_TRASH=1 (default): those deletions go to the Drive trash
  # (recoverable for ~30 days, but they count against the Drive quota until Google empties the trash).
  # PRUNE_USE_TRASH=0: they are deleted at once. The flag is always set explicitly (rclone's own default is "trash").
  _ta="${RCLONE_SERVE_ARGS//--drive-use-trash=false/}"; _ta="${_ta//--drive-use-trash=true/}"
  if [[ "${PRUNE_USE_TRASH:-1}" == 1 ]]; then _ta="$_ta --drive-use-trash=true"; else _ta="$_ta --drive-use-trash=false"; fi
  RESTIC_OPTS_TRASH+=(-o "rclone.program=$GB_BIN/rclone" -o "rclone.args=serve restic --stdio $RCLONE_NET_ARGS $_ta")
fi
# Every restic call is time-limited (a hung Drive call must not hold backup.lock forever).
# timeout runs restic in its own process group and kills the whole group (restic + its rclone child);
# -k: SIGKILL 60 s after SIGTERM. Override per call: R_TIMEOUT=<duration|0> R ... (0 = no limit).
# Exit code 124 = timed out.
_restic_timeout() {
  case "$1" in
    tag|unlock|snapshots|cat) printf '%s' "$RESTIC_TIMEOUT_META";;
    forget) printf '%s' "$RESTIC_TIMEOUT_FORGET";;
    *) printf '%s' "$RESTIC_TIMEOUT";;
  esac
}
_rt() { local t="${R_TIMEOUT:-${RESTIC_TIMEOUT:-3h}}" rc=0
  if [[ "$t" == 0 ]]; then "$@" || rc=$?; else timeout -k 60 "$t" "$@" || rc=$?; fi
  # backup/check/prune raise their own timeout alerts; the default-bounded metadata steps need one here
  # (a caller that set its own R_TIMEOUT, e.g. status.sh, handles the failure itself).
  if (( rc == 124 || rc == 137 )) && [[ "${R_AUTO_LIMIT:-1}" == 1 && "${R_COMMAND:-}" =~ ^(tag|unlock|snapshots|cat|forget)$ ]]; then
    alert "restic $R_COMMAND timed out (limit $t, rc=$rc)"
  fi
  return "$rc"
}
# File-only diagnostics; logging must never affect a restic call's streams or result.
_restic_call_log() {
  local wrapper="$1" caller="${BASH_SOURCE[2]:-$0}" function="${FUNCNAME[2]:-main}"; shift
  caller="${caller##*/}"
  {
    printf '[%s] restic call: caller=%s:%s pid=%s ppid=%s wrapper=%s cmd=' \
      "$(date '+%F %T %Z')" "$caller" "$function" "$$" "$PPID" "$wrapper"
    printf '%q ' "$@"; printf '\n'
  } 2>/dev/null >>"$LOG" || true
}
R()  { local R_COMMAND="${1:-}" R_AUTO_LIMIT="${R_TIMEOUT:+0}" R_TIMEOUT="${R_TIMEOUT:-$(_restic_timeout "${1:-}")}"; _restic_call_log R "$@"; _rt "$GB_BIN/restic" "${RESTIC_OPTS[@]}" "$@"; }
RT() { local R_COMMAND="${1:-}" R_AUTO_LIMIT="${R_TIMEOUT:+0}" R_TIMEOUT="${R_TIMEOUT:-$(_restic_timeout "${1:-}")}"; _restic_call_log RT "$@"; _rt "$GB_BIN/restic" "${RESTIC_OPTS_TRASH[@]}" "$@"; }   # forget/prune (Drive trash)
RCL() { timeout -k 30 "${RCLONE_TIMEOUT:-300}" "$GB_BIN/rclone" --config "$RCLONE_CONFIG" "$@"; }

restic_lock_error() { grep -qi 'repository is already locked' "$1"; }
# Call only while holding backup.lock; share the budget with promotion and check's startup unlock.
restic_unlock_once() {
  local what="$1" rc=0
  [[ $GB_UNLOCK_DONE == 0 ]] || return 0
  GB_UNLOCK_DONE=1
  R unlock >>"$LOG" 2>&1 || rc=$?
  log "$what: plain restic unlock ran rc=$rc"
  alert "$what: repository was locked; plain restic unlock (stale locks only) was run before retrying"
}
restic_retry_unlock() {  # WRAPPER SUBCOMMAND [args...]; keep stdout unchanged
  local wrapper="$1" cmd="$2" err rc=0; shift 2
  err=$(mktemp "$GB_STATE/restic-error.XXXXXX")
  "$wrapper" "$cmd" --retry-lock "$LOCK_RETRY_WAIT" "$@" 2>"$err" || rc=$?
  cat "$err" >>"$LOG"
  if (( rc != 0 )) && restic_lock_error "$err"; then
    restic_unlock_once "$cmd"
    rc=0
    "$wrapper" "$cmd" --retry-lock "$LOCK_RETRY_WAIT" "$@" 2>"$err" || rc=$?
    cat "$err" >>"$LOG"
  fi
  rm -f "$err"
  return "$rc"
}
# Retry a transient read once; keep only the final attempt's output and error for the caller.
snapshot_list() {  # snapshot_list OUTPUT ERROR [snapshots flags...]
  local out="$1" err="$2" attempt rc; shift 2
  for attempt in 1 2; do
    rc=0
    R snapshots --no-lock "$@" >"$out" 2>"$err" || rc=$?
    cat "$err" >>"$LOG"
    (( rc == 0 )) && return 0
    (( rc == 124 || rc == 137 )) && return "$rc"   # timed out: do not double the wait while holding the lock
    [[ $attempt == 2 ]] || sleep "$SNAPSHOT_LIST_RETRY_S"
  done
  return "$rc"
}

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
    if [[ "$LOCK_JOB" == restore* ]]; then
      echo "backup.lock held for $(lock_age_h)h by: $LOCK_PID restore (a restore has NO time limit, unlike backup/check; only a human should stop it - verify it is still making progress)"
    else
      echo "backup.lock held for $(lock_age_h)h by: $LOCK_PID $LOCK_JOB (past job timeout plus grace)"
    fi
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
  ids=$(R snapshots --no-lock --host "$BACKUP_HOST" --tag incomplete --json | python3 -c 'import json,sys;print("\n".join(s["id"] for s in json.load(sys.stdin) if set(s.get("tags") or []) & {"auto","quick"}))') || return 1
  while IFS= read -r id; do
    [[ -z "$id" ]] || restic_retry_unlock R tag --remove auto,quick "$id" >>"$LOG" 2>&1 || return 1
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
