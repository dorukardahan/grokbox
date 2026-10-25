#!/usr/bin/env bash
# Capacity check, called nightly by check.sh (at most once a day): how full is the fullest local
# filesystem that holds Grok Box's data (df of $GB_STATE, $GB_STAGING and every BACKUP_ROOT), and
# how full is the Drive account quota (rclone about --json, rclone: repositories only, bounded by
# RCLONE_TIMEOUT). Writes key=value state to $GB_STATE/quota.status (readers must tolerate missing
# keys: values that could not be measured are simply absent) and alerts when a usage is at or over
# QUOTA_ALERT_PCT (90). Never fatal: a failed/unparsable Drive query is one log line, and the exit
# code is always 0.
source "$(dirname "$0")/lib.sh"
if [[ ! "${QUOTA_ALERT_PCT:-90}" =~ ^[0-9]+$ ]]; then
  log "quota: QUOTA_ALERT_PCT='${QUOTA_ALERT_PCT}' is not a number; using 90"; QUOTA_ALERT_PCT=90; fi
QUOTA_ALERT_PCT=$((10#$QUOTA_ALERT_PCT))   # e.g. 090 must not be read as octal
tmp=""; trap '[[ -n "$tmp" ]] && rm -f "$tmp" || true' EXIT
tmp=$(mktemp "$GB_STATE/quota.status.XXXXXX")

# --- local disk: fullest of the filesystems that hold the state dir, staging or a backup root
disk_pct=""; disk_path=""
declare -A seen=()
for p in "$GB_STATE" "$GB_STAGING" "${BACKUP_ROOTS[@]}"; do
  [[ -d "$p" ]] || continue
  # df -P never splits the mount across lines, but the mount point (field 6+) may contain spaces:
  # blank the first five fields of the whole line instead of reading $6 alone
  read -r pct mnt < <(df -P "$p" 2>/dev/null | awk 'NR==2{pct=$5; gsub(/%/,"",pct); $1=$2=$3=$4=$5=""; sub(/^ +/,""); print pct, $0}') || true
  [[ "${pct:-}" =~ ^[0-9]+$ ]] || continue
  [[ -z "${seen[$mnt]:-}" ]] || continue; seen["$mnt"]=1
  if (( pct > disk_pct )); then disk_pct=$pct; disk_path=$mnt; fi   # disk_pct starts empty -> 0 in (( ))
done

# --- Drive quota (account-wide; only meaningful for rclone: repositories)
drive_pct=""; drive_used=""; drive_other=""; drive_free=""; drive_total=""
if is_rclone_repo; then
  rest="${RESTIC_REPOSITORY#rclone:}"
  if [[ "$rest" == *:* ]]; then remote="${rest%%:*}"; else remote="$GB_REMOTE"; fi
  if about=$(RCL about "$remote:" --json 2>>"$LOG"); then
    # Drive's `used` counts only Drive files: Gmail/Photos usage is reported as `other`, while
    # `total` is the whole account quota. drive_pct must reflect the account-wide usage, or a
    # quota filled by mail/photos would never reach the alert threshold.
    drive_lines=$(python3 -c '
import json,sys
try:
    d = json.loads(sys.stdin.read())
    if not isinstance(d, dict): raise TypeError
    def num(key):
        v = d.get(key)
        return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    u, o, t, f = num("used"), num("other"), num("total"), num("free")
    if u is not None: print(f"drive_used={int(u)}")
    if o is not None: print(f"drive_other={int(o)}")
    if t is not None: print(f"drive_total={int(t)}")
    if f is not None: print(f"drive_free={int(f)}")
    if t:   # integer floor, never rounding up: 89.9% must not fire a 90% alert
        used = t - f if f is not None else (u or 0) + (o or 0)
        print(f"drive_pct={int(used) * 100 // int(t)}")
except (AttributeError, TypeError, ValueError): sys.exit(1)
' <<<"$about") || { drive_lines=""; log "quota: cannot parse rclone about output (non-fatal)"; }
    if [[ -n "$drive_lines" ]]; then
      drive_pct=$(sed -n 's/^drive_pct=//p'     <<<"$drive_lines")
      drive_used=$(sed -n 's/^drive_used=//p'   <<<"$drive_lines")
      drive_other=$(sed -n 's/^drive_other=//p' <<<"$drive_lines")
      drive_free=$(sed -n 's/^drive_free=//p'   <<<"$drive_lines")
      drive_total=$(sed -n 's/^drive_total=//p' <<<"$drive_lines")
    fi
  else
    log "quota: rclone about $remote: failed (non-fatal; Drive quota unknown)"
  fi
fi

{
  echo "time=$(date +%s)"
  if [[ -n "$disk_pct" ]]; then echo "disk_pct=$disk_pct"; echo "disk_path=$disk_path"; fi
  if [[ -n "$drive_used" ]]; then echo "drive_used=$drive_used"; fi
  if [[ -n "$drive_other" ]]; then echo "drive_other=$drive_other"; fi
  if [[ -n "$drive_free" ]]; then echo "drive_free=$drive_free"; fi
  if [[ -n "$drive_total" ]]; then echo "drive_total=$drive_total"; fi
  if [[ -n "$drive_pct" ]]; then echo "drive_pct=$drive_pct"; fi
} > "$tmp"
mv "$tmp" "$GB_STATE/quota.status"; tmp=""

if [[ "$disk_pct" =~ ^[0-9]+$ ]] && (( disk_pct >= QUOTA_ALERT_PCT )); then
  alert "local disk ${disk_pct}% full: ${disk_path} (filesystem holding Grok Box state/staging/backup roots); free space or restores/staging may fail"
fi
if [[ "$drive_pct" =~ ^[0-9]+$ ]] && (( drive_pct >= QUOTA_ALERT_PCT )); then
  # account-wide usage for the message: total-free when known, else used+other (validated integers)
  if [[ -n "$drive_total" && -n "$drive_free" ]]; then eff=$((drive_total - drive_free))
  else eff=$(( ${drive_used:-0} + ${drive_other:-0} )); fi
  used_g=$(awk -v u="$eff" 'BEGIN{printf "%.1f", u/1073741824}')
  total_g=$(awk -v t="${drive_total:-0}" 'BEGIN{printf "%.1f", t/1073741824}')
  alert "Google Drive ${drive_pct}% full (${used_g} GiB of ${total_g} GiB account quota, incl. Gmail/Photos); backups will fail once it fills - empty the Drive trash (pruned data sits there ~30 days with PRUNE_USE_TRASH=1) or raise the quota"
fi
exit 0
