#!/usr/bin/env bash
# Tiny cron replacement (the box has no cron daemon, and background processes do not survive a box
# move). Started by install.sh --schedule (rerun after every box move). Times are in $TZ.
# Jobs are "due"-based, so a slot that passes while another job runs (or the box is off) is caught up:
#   hourly   from minute HOURLY_AT_MIN of each hour      backup.sh (tag auto; waits <= 20 min for a running quick)
#   quick    every QUICK_EVERY_MIN min (not within 10 min after an hourly)   backup.sh --quick (skips if busy)
#   once     after the first successful hourly           test-restore.sh (later monthly via check.sh)
#   daily    from DAILY_CHECK_AT, once per day           check.sh (forget both chains + prune + check)
#   hourly   from minute WATCHDOG_AT_MIN                 watchdog: ALERT if the last HOURLY success (or, before the first one,
#                                                        the scheduler's first start) is >= ALERT_NO_SUCCESS_HOURS old
# Jobs run one at a time in the foreground of this loop. `touch state/PAUSE` pauses new jobs.
# If scheduler.sh, lib.sh or the config file change (and still parse), the loop re-execs itself between jobs.
source "$(dirname "$0")/lib.sh"
set +e; trap - ERR   # the loop must never die on a stray non-zero status
# -w 75: a just-killed predecessor's `sleep` child may hold the lock for up to a minute
exec 8>>"$GB_STATE/scheduler.lock"; flock -w 75 8 || exit 0
echo $$ > "$GB_STATE/scheduler.pid"
sig(){ cat "$GB_DIR/scheduler.sh" "$GB_DIR/lib.sh" "$GB_CONFIG" | md5sum; }
SIG=$(sig)
CHECK_H=$((10#${DAILY_CHECK_AT%%:*})); CHECK_M=$((10#${DAILY_CHECK_AT##*:}))
# first start on a box: first daily check tomorrow (not right now, possibly during the first upload)
[[ -s "$GB_STATE/sched-check" ]] || date +%F > "$GB_STATE/sched-check"
mark_first_start
log "scheduler started pid $$ (quick every ${QUICK_EVERY_MIN}m)"
RC=0; run(){ RC=0; "$@" 8>&- || RC=$?; (( RC == 0 )) || log "scheduler: $(basename "$1") ${2:-} exited rc=$RC"; return 0; }
get(){ cat "$GB_STATE/$1" 2>/dev/null || echo 0; }
while true; do
  date +%s > "$GB_STATE/scheduler.heartbeat"   # dead-man file: status.sh flags a loop that stopped ticking
  sleep $(( 60 - $(date +%-S) )) 8>&-
  if [[ "$(sig)" != "$SIG" ]]; then
    if bash -n "$GB_DIR/scheduler.sh" && bash -n "$GB_DIR/lib.sh" && bash -c 'source "$1"' _ "$GB_DIR/lib.sh" >/dev/null 2>&1; then
      log "scheduler: code/config changed -> re-exec"; exec 8>&-; exec "$GB_DIR/scheduler.sh"
    else alert "scheduler: new scheduler.sh/lib.sh/config does not parse; keeping the old code running"; SIG=$(sig); fi
  fi
  [[ -f "$GB_STATE/PAUSE" ]] && continue
  now=$(date +%s); m=$(date +%-M); h=$(date +%-H); hour=$(date +%F-%H); day=$(date +%F)
  if (( m >= HOURLY_AT_MIN )) && [[ "$(get sched-backup)" != "$hour" ]]; then
    echo "$hour" > "$GB_STATE/sched-backup"; echo "$now" > "$GB_STATE/sched-backup-at"
    run "$GB_DIR/backup.sh" --wait 1200
    if [[ -f "$GB_STATE/last-success" && ! -f "$GB_STATE/last-test-restore" && ! -f "$GB_STATE/test-restore-attempted" ]]; then
      date +%s > "$GB_STATE/test-restore-attempted"; run "$GB_DIR/test-restore.sh"; fi
  elif (( QUICK_EVERY_MIN > 0 && now - $(get sched-quick-at) >= QUICK_EVERY_MIN * 60 - 30 \
          && now - $(get sched-backup-at) >= 600 )); then
    echo "$now" > "$GB_STATE/sched-quick-at"; run "$GB_DIR/backup.sh" --quick
  fi
  if (( h > CHECK_H || (h == CHECK_H && m >= CHECK_M) )) && [[ "$(get sched-check)" != "$day" ]]; then
    echo "$day" > "$GB_STATE/sched-check"; LOCK_WAIT=60 run "$GB_DIR/check.sh"
    (( RC == 75 )) && rm -f "$GB_STATE/sched-check"   # a backup held the lock: retry next minute
  fi
  if (( m >= WATCHDOG_AT_MIN )) && [[ -s "$GB_STATE/last-success" || -s "$GB_STATE/first-start" ]] && [[ "$(get sched-watchdog)" != "$hour" ]]; then
    echo "$hour" > "$GB_STATE/sched-watchdog"
    if [[ -s "$GB_STATE/last-success" ]]; then ref=$(get last-success); what="last: $(date -d "@$ref" '+%F %H:%M')"
    else ref=$(get first-start); what="none since the scheduler first started"; fi
    age_h=$(( ( $(date +%s) - ref ) / 3600 ))
    if (( age_h >= ALERT_NO_SUCCESS_HOURS )); then
      if ! lock_busy; then
        alert "no successful HOURLY snapshot for ${age_h}h ($what); check $LOG"
      else
        problem=$(lock_problem)
        if [[ -n "$problem" ]]; then alert "$problem"
        else log "watchdog: last hourly success ${age_h}h ago but a backup is running now"; fi
      fi
    fi
  fi
done
