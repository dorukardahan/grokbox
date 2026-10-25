#!/usr/bin/env bash
# Capacity check, called nightly by check.sh: how full is the fullest local filesystem that holds
# Grok Box's data (df of $GB_STATE, $GB_STAGING and every BACKUP_ROOT), and how full is the Drive
# quota (rclone about --json, rclone: repositories only, bounded by RCLONE_TIMEOUT). Writes
# key=value state to $GB_STATE/quota.status (readers must tolerate missing keys: values that could
# not be measured are simply absent) and alerts when a usage is at or over QUOTA_ALERT_PCT (90).
# Never fatal: a failed/unparsable Drive query is one log line, and the exit code is always 0.
source "$(dirname "$0")/lib.sh"
tmp=""; trap '[[ -n "$tmp" ]] && rm -f "$tmp" || true' EXIT
tmp=$(mktemp "$GB_STATE/quota.status.XXXXXX")

# --- local disk: fullest of the filesystems that hold the state dir, staging or a backup root
disk_pct=""; disk_path=""
declare -A seen=()
for p in "$GB_STATE" "$GB_STAGING" "${BACKUP_ROOTS[@]}"; do
  [[ -d "$p" ]] || continue
  read -r pct mnt < <(df -P "$p" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5, $6}') || true
  [[ "${pct:-}" =~ ^[0-9]+$ ]] || continue
  [[ -z "${seen[$mnt]:-}" ]] || continue; seen["$mnt"]=1
  if (( pct > disk_pct )); then disk_pct=$pct; disk_path=$mnt; fi   # disk_pct starts empty -> 0 in (( ))
done

# --- Drive quota (account-wide; only meaningful for rclone: repositories)
drive_pct=""; drive_used=""; drive_total=""
if is_rclone_repo; then
  rest="${RESTIC_REPOSITORY#rclone:}"
  if [[ "$rest" == *:* ]]; then remote="${rest%%:*}"; else remote="$GB_REMOTE"; fi
  if about=$(RCL about "$remote:" --json 2>>"$LOG"); then
    drive_lines=$(python3 -c '
import json,sys
try: d = json.loads(sys.stdin.read())
except ValueError: sys.exit(1)
u = d.get("used"); t = d.get("total")
if u is not None: print(f"drive_used={int(u)}")
if t is not None: print(f"drive_total={int(t)}")
if u is not None and t: print(f"drive_pct={round(int(u) * 100 / int(t))}")
' <<<"$about") || { drive_lines=""; log "quota: cannot parse rclone about output (non-fatal)"; }
    if [[ -n "$drive_lines" ]]; then
      drive_pct=$(sed -n 's/^drive_pct=//p'  <<<"$drive_lines")
      drive_used=$(sed -n 's/^drive_used=//p' <<<"$drive_lines")
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
  if [[ -n "$drive_total" ]]; then echo "drive_total=$drive_total"; fi
  if [[ -n "$drive_pct" ]]; then echo "drive_pct=$drive_pct"; fi
} > "$tmp"
mv "$tmp" "$GB_STATE/quota.status"; tmp=""

if [[ "$disk_pct" =~ ^[0-9]+$ ]] && (( disk_pct >= QUOTA_ALERT_PCT )); then
  alert "local disk ${disk_pct}% full: ${disk_path} (filesystem holding Grok Box state/staging/backup roots); free space or restores/staging may fail"
fi
if [[ "$drive_pct" =~ ^[0-9]+$ ]] && (( drive_pct >= QUOTA_ALERT_PCT )); then
  used_g=$(awk -v u="${drive_used:-0}" 'BEGIN{printf "%.1f", u/1073741824}')
  total_g=$(awk -v t="${drive_total:-0}" 'BEGIN{printf "%.1f", t/1073741824}')
  alert "Google Drive ${drive_pct}% full (${used_g} GiB of ${total_g} GiB); backups will fail once it fills - empty the Drive trash (pruned data sits there ~30 days with PRUNE_USE_TRASH=1) or raise the quota"
fi
exit 0
