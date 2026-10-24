#!/usr/bin/env bash
# Safe restore: NEVER writes over live files. Restores into $RESTORE_BASE/restore-<date>-<snap>/.
# Usage:
#   restore.sh list                         # list snapshots
#   restore.sh ls <snap|latest> [path]      # browse a snapshot
#   restore.sh <snap|latest> [path...]      # restore whole snapshot or given paths into the restore dir
#   restore.sh <snap|latest> --missing-only [--yes] [path...]
#       then copy back ONLY files that are missing live (asks first; --yes = no question, use only
#       after the human agreed). Existing files are never overwritten.
source "$(dirname "$0")/lib.sh"; need_creds
case "${1:-}" in
  ""|-h|--help) sed -n 2,10p "$0"; exit 0;;
  list) R snapshots --host "$BACKUP_HOST"; exit;;
  ls) R ls --host "$BACKUP_HOST" "${2:-latest}" ${3:+"$3"}; exit;;
esac
SNAP="$1"; shift; MISSING=0; YES=0
while [[ "${1:-}" == --missing-only || "${1:-}" == --yes ]]; do
  [[ "$1" == --missing-only ]] && MISSING=1 || YES=1; shift; done
DEST="$RESTORE_BASE/restore-$(date +%Y%m%d-%H%M%S)-$SNAP"
[[ -e "$DEST" ]] && { echo "exists: $DEST"; exit 1; }
INC=(); for p in "$@"; do INC+=(--include "$p"); done
log "restore $SNAP ${*:-<all>} -> $DEST"
R restore "$SNAP" --host "$BACKUP_HOST" --target "$DEST" "${INC[@]}" --verify
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
  while IFS= read -r -d '' f; do mkdir -p -- "$(dirname -- "$f")"; cp -an -- "$DEST$f" "$f"; done < "$list"
  log "restored $n missing files from $SNAP"; echo "done"
fi
