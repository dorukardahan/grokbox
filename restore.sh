#!/usr/bin/env bash
# Safe restore: NEVER writes over live files. Restores into $RESTORE_BASE/restore-<date>-<snap>/.
# Usage:
#   restore.sh list                         # list snapshots
#   restore.sh ls <snap|latest> [path]      # browse a snapshot
#   restore.sh <snap|latest> [path...]      # restore whole snapshot or given paths into the restore dir
#   restore.sh <snap|latest> --missing-only [--yes] [path...]
#       then copy back ONLY files that are missing live (asks first; --yes = no question, use only
#       after the human agreed). Existing files are never overwritten.
#   restore.sh --any-host <any of the above>   ignore BACKUP_HOST (e.g. config.env lost or host renamed);
#       `latest` then means the newest snapshot of ANY host.
#   restore.sh --host NAME <any of the above>  use snapshots of host NAME instead of BACKUP_HOST
# If BACKUP_HOST has no snapshots at all, the script stops loudly and lists the hosts that do.
source "$(dirname "$0")/lib.sh"; need_creds
R_TIMEOUT=0   # a big restore may legitimately take many hours
HOSTARG=(--host "$BACKUP_HOST")
case "${1:-}" in
  --any-host) HOSTARG=(); shift;;
  --host) BACKUP_HOST="${2:?host name required}"; HOSTARG=(--host "$BACKUP_HOST"); shift 2;;
esac
case "${1:-}" in ""|-h|--help) sed -n 2,14p "$0"; exit 0;; esac
if (( ${#HOSTARG[@]} )); then
  R_TIMEOUT=600 R snapshots --json > "$GB_STATE/restore-hosts.json.tmp" 2>>"$LOG" \
    || { rm -f "$GB_STATE/restore-hosts.json.tmp"; echo "ERROR: cannot list snapshots in $RESTIC_REPOSITORY (Drive/auth/password problem?)" >&2; exit 7; }
  if ! python3 - "$GB_STATE/restore-hosts.json.tmp" "$BACKUP_HOST" <<'PY2'
import json,sys
from collections import Counter
c=Counter(x.get("hostname","?") for x in json.load(open(sys.argv[1])))
if c.get(sys.argv[2]): sys.exit(0)
print(f"ERROR: no snapshots for host '{sys.argv[2]}' in this repository.", file=sys.stderr)
print("Hosts in this repository (snapshot count): " + (", ".join(f"{h} ({n})" for h,n in sorted(c.items())) or "none"), file=sys.stderr)
print("Fix: set BACKUP_HOST in config.env to the old name, or run restore.sh --host <name> ... or restore.sh --any-host ...", file=sys.stderr)
sys.exit(1)
PY2
  then rm -f "$GB_STATE/restore-hosts.json.tmp"; exit 4; fi
  rm -f "$GB_STATE/restore-hosts.json.tmp"
fi
case "${1:-}" in
  list) R snapshots "${HOSTARG[@]}"; exit;;
  ls) R ls "${HOSTARG[@]}" "${2:-latest}" ${3:+"$3"}; exit;;
esac
SNAP="$1"; shift; MISSING=0; YES=0
while [[ "${1:-}" == --missing-only || "${1:-}" == --yes ]]; do
  [[ "$1" == --missing-only ]] && MISSING=1 || YES=1; shift; done
DEST="$RESTORE_BASE/restore-$(date +%Y%m%d-%H%M%S)-$SNAP"
[[ -e "$DEST" ]] && { echo "exists: $DEST"; exit 1; }
INC=(); for p in "$@"; do INC+=(--include "$p"); done
log "restore $SNAP ${*:-<all>} -> $DEST"
R restore "$SNAP" "${HOSTARG[@]}" --target "$DEST" "${INC[@]}" --verify
echo "Restored into $DEST (live files untouched)."
if [[ $MISSING == 1 ]]; then
  list="$GB_STATE/missing-$(date +%s).list0"   # NUL-delimited: any file name is safe
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
