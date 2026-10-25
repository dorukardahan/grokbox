#!/usr/bin/env bash
# Idempotent; safe to rerun any time (especially after a box move). No root needed.
#   install.sh                 verify/download pinned restic+rclone (SHA256-checked), create the password
#                              file from the RESTIC_BACKUP_PASSWORD env var (never printed), print status
#   install.sh --gen-password  no RESTIC_BACKUP_PASSWORD? generate a random password into secrets/restic-pass
#                              (not printed; the human must copy it into a password manager by reading the
#                              file themselves). Refuses to overwrite an existing file.
#   install.sh --show-password print the password file to stdout (only on explicit request by the human)
#   install.sh --init          create the encrypted restic repository (one time, after auth)
#   install.sh --schedule      also start the scheduler (no-op if already running)
#   install.sh --restart-scheduler   (detached) wait until no backup holds the lock, then replace a running
#                              scheduler with the current code. Normally not needed: the scheduler re-execs
#                              itself when scheduler.sh/lib.sh/config change.
#   install.sh --restart-scheduler --force  terminate only the verified lock job, then restart
#   install.sh --stop-scheduler      stop the scheduler loop
source "$(dirname "$0")/lib.sh"
INIT=0; SCHED=0; RESTART=0; GEN=0; SHOW=0; STOP=0; FORCE_RESTART=0
for a in "$@"; do case "$a" in
  --force) FORCE_RESTART=1;; --init) INIT=1;; --schedule) SCHED=1;; --restart-scheduler) RESTART=1; SCHED=1;;
  --gen-password) GEN=1;; --show-password) SHOW=1;; --stop-scheduler) STOP=1;;
  -h|--help) sed -n 2,17p "$0"; exit 0;;
  *) echo "unknown arg $a"; exit 2;; esac; done
if [[ $FORCE_RESTART == 1 ]]; then
  [[ $RESTART == 1 && $STOP == 0 && $INIT == 0 ]] || { echo "--force requires --restart-scheduler only"; exit 2; }
  lock_busy || { echo "backup.lock is free; refusing --force (use --restart-scheduler)"; exit 1; }
  python3 "$GB_DIR/lock-control.py" force "$GB_STATE/backup.lock" || exit 1
fi
chmod +x "$GB_DIR"/*.sh "$GB_DIR"/*.py "$GB_DIR"/rebuild-kit/*.sh "$GB_DIR"/tests/*.sh 2>/dev/null || true
umask 077; mkdir -p "$GB_SECRETS"; chmod 700 "$GB_SECRETS"

if [[ $STOP == 1 ]]; then
  p=$(sched_pid)
  if [[ -n "$p" ]]; then python3 "$GB_DIR/lock-control.py" stop "$GB_STATE/scheduler.lock" "$p" && log "scheduler (pid $p) stopped"; else log "scheduler not running"; fi
  exit 0
fi

# 1) pinned static binaries (re-download + verify against upstream SHA256SUMS if missing/corrupt)
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;;
  *) echo "unsupported architecture $(uname -m) (need x86_64 or aarch64)"; exit 1;;
esac
dl() { if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"; else wget -q -O "$2" "$1"; fi; }
# bin/VERSIONS: arch + pinned versions (3 header lines) followed by the upstream archive checksums.
# Any difference in arch/versions, or a binary failing SHA256SUMS.local, triggers a reinstall.
WANT_HDR=$(printf 'arch=%s\nrestic=%s\nrclone=%s' "$ARCH" "$PINNED_RESTIC" "$PINNED_RCLONE")
if ! (cd "$GB_BIN" 2>/dev/null && [[ -x restic && -x rclone ]] && [[ "$(head -3 VERSIONS 2>/dev/null)" == "$WANT_HDR" ]] \
      && sha256sum -c --quiet SHA256SUMS.local 2>/dev/null); then
  log "binaries missing, corrupt or different from the pinned versions/arch -> downloading pinned restic $PINNED_RESTIC / rclone $PINNED_RCLONE ($ARCH)"
  tmp=$(mktemp -d); mkdir -p "$GB_BIN"
  rb="restic_${PINNED_RESTIC}_linux_${ARCH}.bz2"; rz="rclone-v${PINNED_RCLONE}-linux-${ARCH}.zip"
  (
    cd "$tmp"
    dl "https://github.com/restic/restic/releases/download/v$PINNED_RESTIC/$rb" "$rb"
    dl "https://github.com/restic/restic/releases/download/v$PINNED_RESTIC/SHA256SUMS" rs.sums
    grep " $rb\$" rs.sums | sha256sum -c -
    dl "https://downloads.rclone.org/v$PINNED_RCLONE/$rz" "$rz"
    dl "https://downloads.rclone.org/v$PINNED_RCLONE/SHA256SUMS" rc.sums
    grep " $rz\$" rc.sums | sha256sum -c -
    python3 -c "import bz2,shutil,sys;shutil.copyfileobj(bz2.open(sys.argv[1]),open('restic','wb'))" "$rb"
    python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extract(sys.argv[2],'.')" "$rz" "rclone-v$PINNED_RCLONE-linux-$ARCH/rclone"
    install -m755 restic "$GB_BIN/restic"; install -m755 "rclone-v$PINNED_RCLONE-linux-$ARCH/rclone" "$GB_BIN/rclone"
  )
  { echo "$WANT_HDR"; grep " $rb\$" "$tmp/rs.sums"; grep " $rz\$" "$tmp/rc.sums"; } > "$GB_BIN/VERSIONS"
  rm -rf "$tmp"; (cd "$GB_BIN" && sha256sum restic rclone > SHA256SUMS.local)
fi
log "restic: $("$GB_BIN/restic" version | cut -d' ' -f1-2)  rclone: $("$GB_BIN/rclone" version | head -1)"

mark_first_start
# 2) repo password file (never printed, never overwritten)
if [[ $GEN == 1 ]]; then
  if [[ -s "$RESTIC_PASSWORD_FILE" ]]; then log "restic-pass already exists; not generating a new one"
  else
    python3 -c 'import secrets,sys;sys.stdout.write(secrets.token_urlsafe(36))' > "$RESTIC_PASSWORD_FILE"
    chmod 600 "$RESTIC_PASSWORD_FILE"
    log "generated a random restic password in $RESTIC_PASSWORD_FILE (not printed)"
    echo "IMPORTANT (human): copy the password into your password manager NOW by reading that file yourself."
    echo "Without it the backups cannot be restored. It is the only secret that is never uploaded."
  fi
elif [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
  if [[ -n "${RESTIC_BACKUP_PASSWORD:-}" ]]; then printf '%s' "$RESTIC_BACKUP_PASSWORD" > "$RESTIC_PASSWORD_FILE"; log "created restic-pass from env"
  else log "WARN RESTIC_BACKUP_PASSWORD not set and no restic-pass file (set the box secret, or use --gen-password)"; fi
elif [[ -n "${RESTIC_BACKUP_PASSWORD:-}" ]] && [[ "$(cat "$RESTIC_PASSWORD_FILE")" != "$RESTIC_BACKUP_PASSWORD" ]]; then
  alert "restic-pass file differs from RESTIC_BACKUP_PASSWORD env; keeping the file (the repo was made with it). Fix manually."
fi
[[ -f "$RESTIC_PASSWORD_FILE" ]] && chmod 600 "$RESTIC_PASSWORD_FILE"
[[ -f "$RCLONE_CONFIG" ]] && chmod 600 "$RCLONE_CONFIG"
if is_rclone_repo && [[ ! -s "$RCLONE_CONFIG" ]]; then log "rclone.conf missing -> run ./auth-gdrive.sh"; fi
if [[ $SHOW == 1 ]]; then [[ -s "$RESTIC_PASSWORD_FILE" ]] && { cat "$RESTIC_PASSWORD_FILE"; echo; } || echo "no password file"; fi

# 3) one-time repo creation
if [[ $INIT == 1 ]]; then
  need_creds
  if R cat config >/dev/null 2>&1; then log "repo already exists"; else R init && log "repo initialised at $RESTIC_REPOSITORY"; fi
fi

# 4) scheduler (hourly + quick + one-time test restore + daily check + watchdog)
start_sched(){ setsid nohup "$GB_DIR/scheduler.sh" >>"$GB_LOGS/scheduler.out" 2>&1 < /dev/null & disown; sleep 1; log "scheduler started"; }
if [[ $RESTART == 1 ]]; then
  need_creds
  # detached helper: waits for the backup lock (never interrupts a backup), then swaps the scheduler
  # shellcheck disable=SC2016  # the helper script is single-quoted on purpose
  setsid nohup bash -c '
    cd "$1" || exit 1; exec 9>>"$2/backup.lock"
    until flock -n 9; do sleep 30; done      # no backup/check/restore running now (we hold the lock)
    source "$1/lib.sh"
    p=$(sched_pid)
    if [[ -n "$p" ]]; then
      python3 "$1/lock-control.py" stop "$2/scheduler.lock" "$p" 2>/dev/null || log "scheduler stop refused or failed; continuing restart handoff"
    fi
    sleep 2; flock -u 9; exec 9>&-
    setsid nohup "$1/scheduler.sh" >>"$3/scheduler.out" 2>&1 </dev/null & disown
    echo "[$(date "+%F %T %Z")] scheduler restarted with current code (handoff helper)" >> "$3/backup-$(date +%Y-%m).log"
  ' _ "$GB_DIR" "$GB_STATE" "$GB_LOGS" >>"$GB_LOGS/scheduler.out" 2>&1 < /dev/null & disown
  log "scheduler restart queued: will happen as soon as no backup is running"
elif [[ $SCHED == 1 ]]; then
  need_creds
  if sched_running; then log "scheduler already running"; else start_sched; fi
fi
