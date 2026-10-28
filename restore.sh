#!/usr/bin/env bash
# Safe restore: NEVER writes over live files. Restores into $RESTORE_BASE/restore-<date>-<snap>/.
# list/ls only read the repository; a real restore takes backup.lock first (waits RESTORE_LOCK_WAIT).
# Full usage and exit codes: restore.sh --help
usage() { cat <<'EOF'
Safe restore: never writes over live files. Restores into <RESTORE_BASE>/restore-<date>-<snapshot>/.

Usage:
  restore.sh list                             list snapshots (read-only)
  restore.sh ls <snap|latest> [path]          browse a snapshot (read-only)
  restore.sh <snap|latest> [path...]          restore the whole snapshot or the given paths into
                                              the restore dir (live files are untouched)
  restore.sh <snap|latest> --missing-only [--yes] [path...]
                                              then copy back ONLY files that are missing live
                                              (asks first; --yes skips the question, use it only
                                              after the human agreed). Existing files are never
                                              overwritten.
  restore.sh --any-host <any of the above>    ignore BACKUP_HOST (e.g. config.env lost or the box
                                              was renamed); `latest` then means the newest snapshot
                                              of ANY host
  restore.sh --host NAME <any of the above>   use snapshots of host NAME instead of BACKUP_HOST

`list` and `ls` only read the repository. A real restore takes state/backup.lock for the restic
phase and waits up to RESTORE_LOCK_WAIT (default 600 s) for a running backup or check to finish;
while that phase runs, scheduled backups skip instead of competing for disk and bandwidth. The lock
is released before the optional --missing-only prompt and copy-back (a prompt may wait for a human
answer for a long time, and the copy-back only touches live files, which the next backup picks up).

If BACKUP_HOST has no snapshots at all, the script stops loudly and lists the hosts that do.

Exit codes:
  0    ok (also: nothing to restore, or the --missing-only copy-back was declined)
  2    usage error (unknown option)
  3    missing credentials (restic password file / rclone config)
  4    BACKUP_HOST has no snapshots in this repository (host mismatch; see --host / --any-host)
  5    the restore directory already exists (nothing is ever overwritten; wait a second or use
       another snapshot id)
  7    repository unreachable, or the snapshot list cannot be read (Drive/auth/password problem)
  8    backup.lock stayed busy for RESTORE_LOCK_WAIT seconds (a backup or check is running; retry later)
  9    the restic restore itself failed (the raw restic exit code is in the message and the log)
EOF
}
case "${1:-}" in -h|--help|"") usage; exit 0;; esac
source "$(dirname "$0")/lib.sh"; need_creds
# shellcheck disable=SC2034  # read by _rt in lib.sh
R_TIMEOUT=0   # a big restore may legitimately take many hours
HOSTARG=(--host "$BACKUP_HOST")
case "${1:-}" in
  --any-host) HOSTARG=(); shift;;
  --host) [[ $# -ge 2 ]] || { echo "--host needs a name" >&2; usage >&2; exit 2; }
          BACKUP_HOST="$2"; HOSTARG=(--host "$BACKUP_HOST"); shift 2;;
esac
case "${1:-}" in -h|--help|"") usage; exit 0;; esac
# reject unknown options BEFORE any repository access: the host guard below lists snapshots, and a
# typo in the options must not surface as "repository unreachable" (7) during a Drive outage
case "${1:-}" in list|ls) ;; -*) echo "unknown option ${1:-}" >&2; usage >&2; exit 2;; esac
RTMP=""; trap '[[ -n "$RTMP" ]] && rm -rf "$RTMP" || true' EXIT   # private scratch (mktemp, 600)
# --host guard for this box (a wrong name would silently restore nothing): needs the snapshot list
if (( ${#HOSTARG[@]} )); then
  RTMP=$(mktemp -d "${TMPDIR:-/tmp}/grokbox-restore.XXXXXX")
  if ! R_TIMEOUT=600 R snapshots --no-lock --json > "$RTMP/hosts.json" 2>>"$LOG"; then
    echo "ERROR: cannot list snapshots in $RESTIC_REPOSITORY (Drive/auth/password problem?)" >&2; exit 7; fi
  hrc=0; python3 - "$RTMP/hosts.json" "$BACKUP_HOST" <<'PY2' || hrc=$?
import json,sys
from collections import Counter
try:
    snaps = json.load(open(sys.argv[1]))
except ValueError:
    print("ERROR: the snapshot list is not readable JSON (corrupt output; try again)", file=sys.stderr)
    sys.exit(2)
c = Counter(x.get("hostname","?") for x in snaps)
if c.get(sys.argv[2]): sys.exit(0)
print(f"ERROR: no snapshots for host '{sys.argv[2]}' in this repository.", file=sys.stderr)
print("Hosts in this repository (snapshot count): " + (", ".join(f"{h} ({n})" for h,n in sorted(c.items())) or "none"), file=sys.stderr)
print("Fix: set BACKUP_HOST in config.env to the old name, or run restore.sh --host <name> ... or restore.sh --any-host ...", file=sys.stderr)
sys.exit(1)
PY2
  [[ "$hrc" == 1 ]] && exit 4
  [[ "$hrc" == 0 ]] || exit 7
fi
case "${1:-}" in
  list) R snapshots --no-lock "${HOSTARG[@]}"; exit;;
  ls) R ls --no-lock "${HOSTARG[@]}" "${2:-latest}" ${3:+"$3"}; exit;;
esac
SNAP="$1"; shift; MISSING=0; YES=0
while [[ "${1:-}" == --missing-only || "${1:-}" == --yes ]]; do
  [[ "$1" == --missing-only ]] && MISSING=1 || YES=1; shift; done
[[ "$SNAP" == --* ]] && { echo "unknown option $SNAP" >&2; usage >&2; exit 2; }
DEST="$RESTORE_BASE/restore-$(date +%Y%m%d-%H%M%S)-$SNAP"
[[ -e "$DEST" ]] && { echo "exists: $DEST (never overwritten; wait a second or use another snapshot id)"; exit 5; }
# a real restore writes a lot of scratch data: serialize with the backups (list/ls above skip this)
exec 9>"$GB_STATE/backup.lock"
if ! flock -w "${RESTORE_LOCK_WAIT:-600}" 9; then
  echo "ERROR: a backup or check holds $GB_STATE/backup.lock; waited ${RESTORE_LOCK_WAIT:-600}s. Retry when it is done (or raise RESTORE_LOCK_WAIT in config.env)." >&2
  exit 8
fi
took_lock restore
INC=(); for p in "$@"; do INC+=(--include "$p"); done
log "restore $SNAP ${*:-<all>} -> $DEST"
rrc=0; R restore "$SNAP" "${HOSTARG[@]}" --target "$DEST" "${INC[@]}" --verify || rrc=$?
if [[ "$rrc" != 0 ]]; then
  # A persistent alert only when restic actually wrote something (a real partial restore); a wrong
  # snapshot id fails before any output and would otherwise alert every day until --ack.
  if [[ -e "$DEST" ]]; then
    alert "restic restore of $SNAP failed rc=$rrc (see $LOG); partial output may be in $DEST"
    echo "ERROR: restic restore failed rc=$rrc (see $LOG); partial output may be in $DEST" >&2
  else
    log "restic restore of $SNAP failed rc=$rrc: no output was written (wrong snapshot id?)"
    echo "ERROR: restic restore failed rc=$rrc, no output was written (wrong snapshot id? see $LOG)" >&2; fi
  exit 9; fi
echo "Restored into $DEST (live files untouched)."
exec 9>&-   # release backup.lock here: the --missing-only prompt below may wait for a human answer
if [[ $MISSING == 1 ]]; then
  [[ -n "$RTMP" ]] || RTMP=$(mktemp -d "${TMPDIR:-/tmp}/grokbox-restore.XXXXXX")
  list="$RTMP/missing.list"   # NUL-delimited: any file name is safe
  (cd "$DEST" && find . \( -type f -o -type l \) -print0) \
    | while IFS= read -r -d '' f; do f="${f#.}"; [[ -e "$f" || -L "$f" ]] || printf '%s\0' "$f"; done > "$list"
  n=$(tr -cd '\0' < "$list" | wc -c); echo "$n files exist in the snapshot but are missing live (list: $list)"
  (( n == 0 )) && exit 0
  if [[ $YES == 1 ]]; then a=y
  else read -r -p "Copy these $n missing files back to their original places? (existing files are never overwritten) [y/N] " a; fi
  [[ "$a" == y ]] || exit 0
  umask 022   # recreated parent directories get normal permissions (files keep the snapshot's mode via cp -a)
  while IFS= read -r -d '' f; do mkdir -p -- "$(dirname -- "$f")"; cp -an -- "$DEST$f" "$f"; done < "$list"
  log "restored $n missing files from $SNAP"; echo "done"
fi
