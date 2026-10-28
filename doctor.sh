#!/usr/bin/env bash
# One-screen health check in plain language: one line per topic, each OK / WARN / PROBLEM + what it means
# and what to do. Local only (no network) unless --online.
#   doctor.sh            scheduler + heartbeat, backup lock, last backup, last check, Drive auth (rclone.conf),
#                        quota/disk, test restore, Drive report upload, expected bots, open alerts, latches
#   doctor.sh --online   also one bounded Drive call (rclone about) to prove the token works
#   doctor.sh --json     the same as one JSON object {overall, exit, checks:[{name,status,detail}]}
# Exit: 0 all OK, 1 at least one WARN (no PROBLEM), 2 at least one PROBLEM. Also reachable as status.sh --doctor.
# State files written by other jobs are read defensively: missing or garbled = "unknown", never a crash.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
ONLINE=0; JSON=0
for a in "$@"; do case "$a" in --online) ONLINE=1;; --json) JSON=1;; -h|--help) sed -n 2,9p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
now=$(date +%s)
N=(); S=(); D=()
row(){ S+=("$1"); N+=("$2"); D+=("$3"); }
# Every number from a state file passes lib.sh's num_ok/epoch_ok (bounded plain integers, no octal, no overflow):
# epochf FILE, kv_num FILE KEY, kv_epoch FILE KEY give the value or nothing; isnum tests the result.
epochf(){ epoch_file "$1"; }
isnum(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }
ago(){ local d; isnum "$1" || { echo "unknown"; return; }; d=$(( now - $1 )); (( d < 0 )) && d=0
  if (( d < 3600 )); then echo "$(( d / 60 )) min ago"; elif (( d < 172800 )); then echo "$(( d / 3600 )) h ago"; else echo "$(( d / 86400 )) d ago"; fi; }
at(){ isnum "$1" && date -d "@$1" '+%F %H:%M' || echo "?"; }

# --- open alerts, pause, latches
if [[ -s "$GB_STATE/ALERT" ]]; then
  row PROBLEM alerts "$(wc -l < "$GB_STATE/ALERT") open; newest: $(tail -1 "$GB_STATE/ALERT" | cut -c1-140). Fix the cause, then ./status.sh --ack"
else row OK alerts "none open"; fi
channel_names=$(alert_channels)
if [[ -z "$channel_names" ]]; then
  if [[ "$ALERT_CHANNEL_REQUIRED" == 0 ]]; then row OK "alert channel" "disabled on purpose"
  else row WARN "alert channel" "NO ALERT CHANNEL: failures are only written to state/ALERT and logs, nobody is told. Set ALERT_NTFY_URL, ALERT_WEBHOOK_URL or ALERT_HOOK in config.env (docs/health-and-alerts.md), then run ./test-alert.sh"; fi
elif [[ "$(kv_get "$GB_STATE/alert-delivery.status" result)" == failed ]]; then
  row WARN "alert channel" "last alert delivery FAILED $(ago "$(kv_epoch "$GB_STATE/alert-delivery.status" time)"); see logs/alert-hook.log, run ./test-alert.sh"
elif [[ "$(kv_get "$GB_STATE/alert-test.status" result)" == failed ]]; then
  row WARN "alert channel" "configured ($channel_names), last alert test FAILED; see logs/alert-hook.log, run ./test-alert.sh"
elif [[ "$(kv_get "$GB_STATE/alert-test.status" result)" != ok ]]; then
  row OK "alert channel" "configured ($channel_names), not tested yet: run ./test-alert.sh"
else row OK "alert channel" "configured ($channel_names), test passed"; fi
[[ -f "$GB_STATE/PAUSE" ]] && row WARN paused "state/PAUSE exists: the scheduler starts no jobs (rm state/PAUSE to resume)"
[[ -e "$GUARD_LATCH" ]] && row PROBLEM "stale guard" "latch set ($(cut -d' ' -f2- "$GUARD_LATCH" 2>/dev/null | cut -c1-120)); forget/prune blocked until a good hourly backup; see REBUILD.md, never --force blindly"
[[ -e "$SQLITE_LATCH" ]] && row WARN "sqlite staging" "latch set since $(at "$(epochf "$SQLITE_LATCH")"): a consistent-copy run failed; forget/prune blocked until a fully clean hourly backup"

# --- scheduler + heartbeat. A stale heartbeat is excused only while the scheduler's own verified child job
# (lock-holder pid really holds backup.lock, parent = scheduler, lock taken after the last tick, within the
# job budget: lib.sh heartbeat_job_active) runs; an unrelated or orphaned lock never hides a hung loop.
hb=$(epochf "$GB_STATE/scheduler.heartbeat")
if sched_running; then
  if isnum "$hb" && (( now - hb >= ${HEARTBEAT_MAX_MIN:-90} * 60 )); then
    if heartbeat_job_active "$hb"; then row OK scheduler "running (pid $(sched_pid)); heartbeat $(ago "$hb"), paused while its own job (${LOCK_JOB:-?}, pid $LOCK_PID) holds the lock"
    else row PROBLEM scheduler "running (pid $(sched_pid)) but its loop has not ticked for $(( (now - hb) / 60 )) min and no verified job of its own holds the lock: hung; run ./install.sh --restart-scheduler"; fi
  elif isnum "$hb"; then row OK scheduler "running (pid $(sched_pid)), last tick $(ago "$hb")"
  else row WARN scheduler "running (pid $(sched_pid)), last tick unknown (state/scheduler.heartbeat missing or garbled)"; fi
else row PROBLEM scheduler "NOT running (box moved?): run ./install.sh --schedule"; fi

# --- backup lock. "Alive" means the recorded pid really has backup.lock open (lib.sh lock_record +
# lock_holder_alive via /proc/<pid>/fd), not merely that a /proc entry exists (pid reuse). lock_problem
# waits 2 s for the flock -> record race and names the leftover holder processes for an orphan.
if lock_busy; then
  lp=$(lock_problem)
  if [[ -n "$lp" ]]; then
    row PROBLEM "backup lock" "$lp (nothing is killed automatically; docs/lock-and-prune-safety.md)"
  elif lock_record && lock_holder_alive; then
    row OK "backup lock" "held by ${LOCK_JOB:-?} (pid $LOCK_PID) since $(at "$LOCK_TIME") ($(ago "$LOCK_TIME")): a job is running"
  elif lock_busy; then row WARN "backup lock" "held, holder unverifiable right now (state/lock-holder being written?); run again"
  else row OK "backup lock" "free (a job just finished)"; fi
else row OK "backup lock" "free"; fi

# --- credentials
creds=1
[[ -s "$RESTIC_PASSWORD_FILE" ]] || { creds=0; row PROBLEM credentials "restic password file missing ($RESTIC_PASSWORD_FILE): AGENTS.md step 3 (box secret RESTIC_BACKUP_PASSWORD + ./install.sh)"; }
if is_rclone_repo && [[ ! -s "$RCLONE_CONFIG" ]]; then creds=0; row PROBLEM "drive auth" "rclone config missing ($RCLONE_CONFIG): run ./auth-gdrive.sh"; fi
(( creds == 1 )) && row OK credentials "restic password file present$(is_rclone_repo && echo ", rclone config present")"

# --- last backup (last-backup.result from backup.sh if present, else the classic timestamp files)
lb="$GB_STATE/last-backup.result"
lres=$(kv_get "$lb" result); lt=$(kv_epoch "$lb" time); lsnap=$(kv_get "$lb" snapshot); lfiles=$(kv_num "$lb" files); lunread=$(kv_num "$lb" unreadable)
[[ "$lsnap" =~ ^[0-9a-f]{1,64}$ ]] || lsnap=""
ok_t=$(epochf "$GB_STATE/last-success"); part_t=$(epochf "$GB_STATE/last-partial"); first=$(epochf "$GB_STATE/first-start")
if [[ "$lres" == complete ]] && isnum "$lt" && (( lt > ${ok_t:-0} )); then ok_t=$lt; fi
lim=${ALERT_NO_SUCCESS_HOURS:-3}
if [[ -n "$ok_t" ]]; then
  age_h=$(( (now - ok_t) / 3600 ))
  det="complete $(ago "$ok_t") ($(at "$ok_t"))"; [[ -n "$lsnap" ]] && det+=", snapshot $lsnap"; isnum "$lfiles" && det+=", $lfiles files"
  if (( age_h >= lim )); then row PROBLEM "last backup" "last COMPLETE hourly backup is ${age_h} h old (limit ALERT_NO_SUCCESS_HOURS=$lim); see logs/backup-$(date +%Y-%m).log"
  elif [[ "$lres" =~ ^(incomplete|failed|timeout)$ ]] && isnum "$lt" && (( lt > ok_t )); then
    row WARN "last backup" "the last run ($(at "$lt")) ended $lres${lunread:+ ($lunread unreadable file(s))}; last complete one $(ago "$ok_t")"
  elif isnum "$part_t" && (( part_t >= ok_t )); then row WARN "last backup" "the last run ($(at "$part_t")) was INCOMPLETE (unreadable files, see logs); last complete one $(ago "$ok_t")"
  else row OK "last backup" "$det"; fi
elif isnum "$first" && (( now - first >= ${FIRST_SUCCESS_GRACE_HOURS:-2} * 3600 )); then
  row PROBLEM "last backup" "no complete hourly backup yet, $(( (now - first) / 3600 )) h after the first start; run ./backup.sh and read its output"
else row WARN "last backup" "none yet (just installed; the first hourly run or ./backup.sh creates it)"; fi

# --- hourly slots: completed local clock hours only; the partial install hour is excused.
window=$(num_ok "$HOURLY_SLOT_WINDOW_H"); window=${window:-24}
miss_warn=$(num_ok "$HOURLY_MISS_WARN"); miss_warn=${miss_warn:-1}
skipped_backup || true
mapfile -t slots < <(python3 - "$GB_STATE/hourly-history" "$now" "$window" "$miss_warn" "${first:-0}" "${SKIP_TIME:-0}" "$SKIP_HOLDER" <<'PY'
import re, sys, time
path, now, window, warn, first, skip, holder = sys.argv[1:]
now, window, warn, first, skip = map(int, (now, window, warn, first, skip))
history = []
try:
    for line in open(path):
        value = line.strip()
        if not re.fullmatch(r'[0-9]{1,10}', value) or not 0 < int(value) < 8589934592:
            raise ValueError('invalid epoch')
        history.append(int(value))
except (OSError, ValueError, UnicodeError):
    history = []
if not history:
    fresh = first > 0 and now - first < 86400
    print('OK' if fresh else 'WARN')
    print('no history yet' if fresh else 'no hourly history (state/hourly-history missing)')
else:
    clock = time.localtime(now)
    end = now - clock.tm_min * 60 - clock.tm_sec
    start = max(end - window * 3600, first, 0)
    # Bound work even if a window is configured larger than the retained history.
    covered = {end + (t - end) // 3600 * 3600 for t in history if t < end}
    count = max(0, (end - start) // 3600)
    missed = count - sum(end - count * 3600 <= t < end for t in covered)
    hours = []
    for i in range(min(count, len(covered) + 6)):
        hour = end - (count - i) * 3600
        if hour not in covered:
            hours.append(time.strftime('%H:00', time.localtime(hour)))
            if len(hours) == 6:
                break
    detail = f'{missed} missed of {count} completed hours'
    if missed:
        detail += ': ' + ', '.join(hours) + (' ...' if missed > 6 else '')
        skip_hour = end + (skip - end) // 3600 * 3600
        if skip > 0 and end - count * 3600 <= skip_hour < end and skip_hour not in covered:
            detail += f'; backup skipped at {time.strftime("%F %H:%M", time.localtime(skip))} (held by {holder})'
    print('WARN' if missed >= warn else 'OK')
    print(detail)
PY
)
row "${slots[0]:-WARN}" "hourly slots" "${slots[1]:-unknown}"

# --- quick chain and the most recent hourly lock skip
quick=$(epochf "$GB_STATE/last-success-quick"); quick_limit=$(quick_max_age_s)
if [[ "$QUICK_EVERY_MIN" == 0 ]]; then row OK "quick chain" "disabled (QUICK_EVERY_MIN=0)"
elif isnum "$quick"; then
  if (( now - quick >= quick_limit )); then row WARN "quick chain" "last complete quick backup $(ago "$quick") (limit $(( quick_limit / 60 )) min)"
  else row OK "quick chain" "complete $(ago "$quick")"; fi
elif isnum "$first" && (( now - first < 7200 )); then row OK "quick chain" "none yet (first-start grace)"
else row WARN "quick chain" "none yet (first start $(ago "$first"))"; fi
if skipped_backup; then
  row WARN "skipped backup" "an hourly backup gave up waiting for the lock at $(at "$SKIP_TIME") (held by $SKIP_HOLDER); the next hourly will retry"
else row OK "skipped backup" "none pending"; fi

# --- last check (last-check.result from check.sh if present, else state/last-check)
lc="$GB_STATE/last-check.result"
cres=$(kv_get "$lc" result); ct=$(kv_epoch "$lc" time); cpr=$(kv_get "$lc" pruned); cskip=$(kv_get "$lc" prune_skip)
[[ "$cskip" =~ ^(latch|last-backup-not-complete|check-failed)$ ]] || cskip=""
[[ "$cres" =~ ^(ok|failed|skipped)$ ]] || cres=""
isnum "$ct" || ct=$(epochf "$GB_STATE/last-check")
pr=""; case "$cpr" in 1) pr=", pruned";; 0) pr=", prune skipped";; esac
if [[ "$cpr" == 0 || -n "$cskip" ]]; then
  since=$(epochf "$GB_STATE/prune-skipped-since")
  days=$(num_ok "$PRUNE_SKIP_PROBLEM_DAYS"); days=${days:-3}
  # Compare days rather than multiplying a configurable value by seconds.
  severity=WARN
  if isnum "$since" && (( (now - since) / 86400 >= days )); then severity=PROBLEM; fi
  pr=", prune skipped (${cskip:-unknown}); since $(at "$since") ($(ago "$since"))"
fi
if [[ -e "$GB_STATE/CHECK_FAILED" ]]; then row PROBLEM "last check" "restic check FAILED (latch state/CHECK_FAILED; prune blocked until a check passes)$pr: see the log, docs/runbooks if present, then ./check.sh"
elif [[ "$cres" == failed ]]; then row PROBLEM "last check" "FAILED at $(at "$ct")$pr; see logs/backup-$(date +%Y-%m).log"
elif [[ "$cpr" == 0 || -n "$cskip" ]]; then
  row "$severity" "last check" "${cres:-unknown} $(ago "$ct")$pr"
elif isnum "$ct"; then
  if (( now - ct >= 48 * 3600 )); then row WARN "last check" "$(ago "$ct") (expected daily at ${DAILY_CHECK_AT:-04:40}); is the scheduler running?"
  else row OK "last check" "${cres:-ok} $(ago "$ct")$pr"; fi
elif [[ -n "$ok_t" ]] && isnum "$first" && (( now - first >= 48 * 3600 )); then row WARN "last check" "never ran, although backups exist for 2+ days (daily at ${DAILY_CHECK_AT:-04:40})"
else row OK "last check" "not yet (first daily check runs at ${DAILY_CHECK_AT:-04:40} the day after the first start)"; fi

# --- Drive auth (cheap: rclone.conf has a token for GB_REMOTE; --online: one bounded `rclone about`)
if ! is_rclone_repo; then row OK "drive auth" "not an rclone: repository ($RESTIC_REPOSITORY); nothing to authorise"
elif [[ -s "$RCLONE_CONFIG" ]]; then
  if python3 - "$RCLONE_CONFIG" "$GB_REMOTE" <<'PY' 2>/dev/null
import configparser,sys
c=configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
sys.exit(0 if c.has_section(sys.argv[2]) and c[sys.argv[2]].get("token") else 1)
PY
  then
    if (( ONLINE == 1 )); then
      if RCL about "$GB_REMOTE:" >/dev/null 2>&1; then row OK "drive auth" "token for remote $GB_REMOTE present and Drive answers (rclone about)"
      else row PROBLEM "drive auth" "token for remote $GB_REMOTE present but Drive does not answer (revoked/expired token or no network): ./auth-gdrive.sh --test, then --reauth"; fi
    else row OK "drive auth" "token for remote $GB_REMOTE present (not tested online; add --online)"; fi
  else row PROBLEM "drive auth" "rclone config has no token for remote [$GB_REMOTE]: run ./auth-gdrive.sh"; fi
fi

# --- quota / disk (state/quota.status, written once a day by quota-check.sh during the daily check)
q="$GB_STATE/quota.status"
qp="${QUOTA_ALERT_PCT:-90}"; [[ "$qp" =~ ^[0-9]+$ ]] || qp=90; qp=$((10#$qp))
dpct=$(kv_num "$q" drive_pct); kpct=$(kv_num "$q" disk_pct); qt=$(kv_epoch "$q" time); kpath=$(kv_get "$q" disk_path | cut -c1-80)
if ! isnum "$dpct" && ! isnum "$kpct"; then
  row WARN "quota/disk" "unknown: no usable state/quota.status (written daily by quota-check.sh) - Drive/disk usage cannot be seen"
elif isnum "$qt" && (( now - qt >= 48 * 3600 )); then
  row WARN "quota/disk" "measured $(ago "$qt"): stale (no quota check for 2+ days, expected daily) - is the daily check running?"
else
  det="Drive ${dpct:-?}% used, local disk ${kpct:-?}% used${kpath:+ ($kpath)}, measured $(ago "$qt")"
  worst=0; isnum "$dpct" && worst=$dpct; isnum "$kpct" && (( kpct > worst )) && worst=$kpct
  if (( worst >= qp )); then row PROBLEM "quota/disk" "$det: nearly full (${qp}%+): free space or a bigger plan, else backups will fail"
  elif (( worst >= 80 )); then row WARN "quota/disk" "$det: getting full (80%+)"
  else row OK "quota/disk" "$det"; fi
fi

# --- test restore (state/test-restore.result from test-restore.sh, else state/last-test-restore)
tr="$GB_STATE/test-restore.result"
tres=$(kv_get "$tr" result); tt=$(kv_epoch "$tr" time); tf=$(kv_num "$tr" files); tm=$(kv_num "$tr" mismatches)
[[ "$tres" =~ ^(ok|failed)$ ]] || tres=""
isnum "$tt" || { tt=$(epochf "$GB_STATE/last-test-restore"); [[ -n "$tt" && -z "$tres" ]] && tres=ok; }
weekly=""; [[ "${TEST_RESTORE_WEEKDAY:-}" =~ ^[0-6]$ ]] && weekly=1
if [[ "$tres" == failed ]]; then row PROBLEM "test restore" "FAILED at $(at "$tt") (${tf:-?} files restored, ${tm:-?} mismatches): see state/test-restore-result.txt and the log; rerun ./test-restore.sh"
elif isnum "$tt"; then
  d=$(( (now - tt) / 86400 ))
  if (( d > 35 )) || { [[ -n "$weekly" ]] && (( d > 10 )); }; then row WARN "test restore" "last OK one is $d days old (expected $([[ -n $weekly ]] && echo weekly || echo monthly)); run ./test-restore.sh"
  else row OK "test restore" "ok $(ago "$tt")${tf:+ ($tf files verified, ${tm:-0} mismatches)}"; fi
elif [[ -n "$ok_t" ]] && isnum "$first" && (( now - first > 35 * 86400 )); then row WARN "test restore" "never succeeded, $(( (now - first) / 86400 )) days after install: run ./test-restore.sh"
else row OK "test restore" "not yet (runs once after the first hourly backup, then $([[ -n $weekly ]] && echo weekly || echo monthly))"; fi

# --- Drive report upload (state/report-upload.status from report.sh)
ru="$GB_STATE/report-upload.status"; rres=$(kv_get "$ru" result); rt=$(kv_epoch "$ru" time); rstage=$(kv_get "$ru" stage)
if [[ "$rres" == failed && "$rstage" == build ]]; then row WARN "drive report" "latest-backup-report.txt could not be built $(ago "$rt") (report.sh error, see the log); retried after the next hourly backup"
elif [[ "${DRIVE_REPORT:-1}" != 1 ]]; then row OK "drive report" "disabled (DRIVE_REPORT=0)"
elif ! is_rclone_repo; then row OK "drive report" "written locally only (not an rclone: repository): state/latest-backup-report.txt"
elif [[ "$rres" == failed ]]; then row WARN "drive report" "upload of latest-backup-report.txt FAILED $(ago "$rt"); retried after the next hourly backup (see the log)"
elif [[ "$rres" == ok ]]; then row OK "drive report" "latest-backup-report.txt uploaded $(ago "$rt")"
else row OK "drive report" "no upload yet (after the next hourly backup)"; fi

# --- expected bots (EXPECTED_BOTS roster vs the latest server-side export)
eb=$("$GB_DIR/expected-bots.sh" 2>/dev/null); erc=$?
if (( ${#EXPECTED_BOTS[@]} == 0 )); then
  suggested=$("$GB_DIR/expected-bots.sh" --suggest 2>/dev/null); src=$?
  if (( src == 2 )); then
    eb="no roster configured (no server-side export on this box)"
  elif (( src == 0 )) && [[ "$suggested" == EXPECTED_BOTS=\(\)* ]]; then
    eb="no roster configured (no active exported bots)"
  elif (( src == 0 )) && [[ "$EXPECTED_BOTS_REQUIRED" != 0 ]]; then
    erc=1
    eb="no roster configured: bots could silently drop out of the export unnoticed; run ./expected-bots.sh --suggest and paste the result into config.env (EXPECTED_BOTS)"
  elif (( src == 1 )); then eb="${suggested%%$'\n'*}"; erc=1; fi
fi
case "$erc" in 0) row OK "expected bots" "$eb";; 1) row WARN "expected bots" "$eb";; *) row WARN "expected bots" "${eb:-check failed}";; esac

# --- daily export (every active per-bot check)
ef=$("$GB_DIR/export-freshness.sh" 2>/dev/null); erc=$?
ef=${ef%%$'\n'*}
case "$erc" in
  0) row OK "daily export" "$ef";;
  2)
    first=$(epoch_file "$GB_STATE/first-start")
    if [[ -n "$first" ]] && (( $(date +%s) - first < EXPORT_MISSED_HOURS * 3600 )); then
      row OK "daily export" "$ef (first-start grace)"
    else
      row WARN "daily export" "$ef"
    fi;;
  *) row WARN "daily export" "${ef:-check failed}";;
esac

# --- export warnings (INDEX.md; diagnostic only)
ew=$("$GB_DIR/export-freshness.sh" --warnings 2>/dev/null); erc=$?
case "$erc" in
  0) row OK "export warnings" "$ew";;
  2) row OK "export warnings" "no export yet";;
  *) row WARN "export warnings" "${ew:-check failed}";;
esac

# --- output
overall=OK; code=0
for s in "${S[@]}"; do [[ $s == PROBLEM ]] && { overall=PROBLEM; code=2; }; [[ $s == WARN && $code == 0 ]] && { overall=WARN; code=1; }; done
if (( JSON == 1 )); then
  for i in "${!N[@]}"; do printf '%s\0%s\0%s\0' "${S[$i]}" "${N[$i]}" "${D[$i]}"; done | python3 -c '
import json,sys
p=sys.stdin.buffer.read().decode("utf-8","replace").split("\0")[:-1]
rows=[{"status":p[i],"name":p[i+1],"detail":p[i+2]} for i in range(0,len(p)-2,3)]
print(json.dumps({"overall":sys.argv[1],"exit":int(sys.argv[2]),"time":int(sys.argv[3]),"host":sys.argv[4],"checks":rows},ensure_ascii=False,indent=1))' "$overall" "$code" "$now" "$BACKUP_HOST"
else
  echo "Grok Box doctor  $(date '+%F %H:%M %Z')  host $BACKUP_HOST  repo $RESTIC_REPOSITORY"
  for i in "${!N[@]}"; do printf '%-8s %s: %s\n' "${S[$i]}" "${N[$i]}" "${D[$i]}"; done
  echo "Overall: $overall"
fi
exit "$code"
