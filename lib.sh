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
export TZ
umask 077   # state, logs, staging and restored scratch data are private by default
mkdir -p "$GB_STATE" "$GB_LOGS" "$GB_STAGING" "$RESTIC_CACHE_DIR"
chmod 700 "$GB_STATE" "$GB_LOGS" "$GB_STAGING" 2>/dev/null || true
LOG="$GB_LOGS/backup-$(date +%Y-%m).log"
ALERTS_LOG="$GB_LOGS/alerts.log"
log()  { echo "[$(date '+%F %T %Z')] $*" | tee -a "$LOG" >&2; }
# alert: loud, persistent failure marker. state/ALERT stays until `status.sh --ack`.
alert(){
  local msg
  msg="[$(date '+%F %T %Z')] [$(basename "$0")] $*"
  log "ALERT: $*"
  echo "$msg" >> "$GB_STATE/ALERT"
  echo "$msg" >> "$ALERTS_LOG"
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
lock_age_h() {  # hours the current holder has held backup.lock (empty if free or holder unknown)
  lock_busy || return 0
  local t p rest; read -r t p rest < "$GB_STATE/lock-holder" 2>/dev/null || return 0
  [[ -n "$p" && -d "/proc/$p" ]] || return 0
  echo $(( ( $(date +%s) - t ) / 3600 ))
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
