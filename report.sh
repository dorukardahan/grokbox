#!/usr/bin/env bash
# Writes state/latest-backup-report.txt (plain text, human readable, in $TZ: last backup time/result/size/files/
# added/duration, repository size, last check + prune, last test restore) and, for rclone: repositories with
# DRIVE_REPORT=1, uploads it into the PARENT of GB_FOLDER (e.g. GrokBox/restic -> GrokBox/latest-backup-report.txt,
# never inside restic/). scheduler.sh runs it after every hourly backup, daily check and test restore.
# The report holds no secrets, paths, ids or e-mail addresses (only BACKUP_HOST). `rclone copyto` replaces the
# file in place. A failed upload never fails anything: it is written to state/report-upload.status
# (result=ok|failed, time) and shown by status.sh and doctor.sh.
#   report.sh               write + upload        report.sh --no-upload   write only
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
R_TIMEOUT=300   # the report must never hold things up: short, tolerant restic calls
UPLOAD=1
for a in "$@"; do case "$a" in --no-upload) UPLOAD=0;; -h|--help) sed -n 2,9p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
OUT="$GB_STATE/latest-backup-report.txt"; NAME="latest-backup-report.txt"
SNAP="$GB_STATE/report-snapshot.json"; STATS="$GB_STATE/report-stats.json"
rm -f "$SNAP" "$STATS"
if [[ -s "$RESTIC_PASSWORD_FILE" ]] && { ! is_rclone_repo || [[ -s "$RCLONE_CONFIG" ]]; }; then
  # newest hourly snapshot (its summary carries files/bytes/added/duration) + raw repository size; both optional
  R snapshots --host "$BACKUP_HOST" --tag auto --latest 1 --json > "$SNAP.tmp" 2>/dev/null && mv "$SNAP.tmp" "$SNAP"
  R stats --mode raw-data --json > "$STATS.tmp" 2>/dev/null && mv "$STATS.tmp" "$STATS"
  rm -f "$SNAP.tmp" "$STATS.tmp"
fi
nalerts=0; [[ -s "$GB_STATE/ALERT" ]] && nalerts=$(wc -l < "$GB_STATE/ALERT")
python3 - "$GB_STATE" "$SNAP" "$STATS" "$BACKUP_HOST" "$nalerts" "${TEST_RESTORE_WEEKDAY:-}" > "$OUT.tmp" <<'PY'
import json, os, sys, time
st, snapf, statsf, host, nalerts, weekday = sys.argv[1:7]
def kv(name):
    d = {}
    try:
        for l in open(os.path.join(st, name), encoding="utf-8", errors="replace"):
            if "=" in l: k, v = l.rstrip("\n").split("=", 1); d[k.strip()] = v.strip()
    except OSError: pass
    return d
def epoch(name):
    try: return int(open(os.path.join(st, name)).read().strip())
    except (OSError, ValueError): return None
def num(v):
    try: return int(float(v))
    except (TypeError, ValueError): return None
def ts(t): return time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(t)) if t else "never"
def size(b):
    if b is None: return "unknown"
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or u == "TB": return f"{b:.0f} {u}" if u == "B" else f"{b:.1f} {u}"
        b /= 1024
def dur(s):
    if s is None: return "unknown"
    s = int(s); return f"{s // 3600} h {s % 3600 // 60} min" if s >= 3600 else (f"{s // 60} min {s % 60} s" if s >= 60 else f"{s} s")
lb = kv("last-backup.result")                      # written by backup.sh (may be absent on older versions)
t_ok, t_part = epoch("last-success"), epoch("last-partial")
snap = {}
try:
    s = json.load(open(snapf)); snap = sorted(s, key=lambda x: x.get("time", ""))[-1] if s else {}
except (OSError, ValueError): pass
sm = snap.get("summary") or {}
def snap_epoch():
    t = snap.get("time", "")
    try:
        from datetime import datetime
        import re
        return int(datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", t).replace("Z", "+00:00")).timestamp())
    except ValueError: return None
def snap_dur():
    try:
        from datetime import datetime
        import re
        f = lambda x: datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", x).replace("Z", "+00:00")).timestamp()
        return int(f(sm["backup_end"]) - f(sm["backup_start"]))
    except (KeyError, ValueError): return None
result = lb.get("result")
when = num(lb.get("time"))
if result not in ("complete", "incomplete", "failed", "timeout"):   # fall back to the classic state files
    if t_ok or t_part:
        result = "incomplete" if (t_part or 0) >= (t_ok or 0) else "complete"; when = max(t_ok or 0, t_part or 0)
    else: result, when = "no backup yet", None
files = num(lb.get("files")) or sm.get("total_files_processed")
tbytes = num(lb.get("bytes")) or sm.get("total_bytes_processed")
added = num(lb.get("added")) or sm.get("data_added_packed", sm.get("data_added"))
dur_s = num(lb.get("duration_s")) if lb.get("duration_s") else snap_dur()
sid = lb.get("snapshot") or snap.get("short_id") or ""
unread = num(lb.get("unreadable"))
try: repo = size(json.load(open(statsf)).get("total_size"))
except (OSError, ValueError, AttributeError): repo = "unknown"
lc = kv("last-check.result"); c_t = num(lc.get("time")) or epoch("last-check"); c_res = lc.get("result") or ("ok" if c_t else "never")
pruned = {"1": "yes", "0": "no"}.get(lc.get("pruned", ""), "unknown")
if os.path.exists(os.path.join(st, "CHECK_FAILED")): c_res = "FAILED (prune blocked until a check passes)"
tr = kv("test-restore.result"); tr_t = num(tr.get("time")) or epoch("last-test-restore"); tr_res = tr.get("result") or ("ok" if tr_t else "never")
L = [f"Grok Box backup report (host {host})", f"Written:            {ts(time.time())}", ""]
L += [f"Last backup:        {ts(when)}", f"Result:             {result}" + (f" ({unread} unreadable file(s))" if unread else "")]
if sid: L.append(f"Snapshot:           {sid}" + (f" (taken {ts(snap_epoch())})" if snap_epoch() and not lb.get("time") else ""))
L += [f"Files:              {files:,}" if isinstance(files, int) else "Files:              unknown",
      f"Source size:        {size(tbytes)}", f"Added this run:     {size(added)}", f"Duration:           {dur(dur_s)}",
      f"Repository size:    {repo}", "",
      f"Last check:         {ts(c_t)}, result: {c_res}, prune: {pruned}",
      f"Last test restore:  {ts(tr_t)}, result: {tr_res}" + (f" ({tr.get('files')} files, {tr.get('mismatches')} mismatches)" if tr.get("files") else ""),
      f"Open alerts:        {nalerts}", "",
      "Schedule: hourly snapshot, quick snapshots in between, daily forget + prune + check, "
      + ("weekly test restore." if weekday else "monthly test restore."),
      "This file is rewritten after every hourly backup; the restic repository itself is in the restic/ folder next to it."]
print("\n".join(L))
PY
rc=$?; rm -f "$SNAP" "$STATS"
if (( rc != 0 )); then log "WARN report: could not build $NAME (python rc=$rc)"; rm -f "$OUT.tmp"; exit 0; fi
mv "$OUT.tmp" "$OUT"
[[ $UPLOAD == 1 ]] || exit 0
if [[ "${DRIVE_REPORT:-1}" != 1 ]]; then log "report: DRIVE_REPORT=0, $NAME written locally only"; exit 0; fi
if ! is_rclone_repo; then log "report: not an rclone: repository, $NAME written locally only"; exit 0; fi
folder="${GB_FOLDER%/}"
if [[ "$folder" != */* ]]; then log "report: GB_FOLDER '$GB_FOLDER' has no parent folder; $NAME not uploaded (it never goes inside the restic folder)"; exit 0; fi
dest="$GB_REMOTE:${folder%/*}/$NAME"
if RCL copyto "$OUT" "$dest" >>"$LOG" 2>&1; then
  kv_write "$GB_STATE/report-upload.status" "result=ok" "time=$(date +%s)"
  log "report: $NAME uploaded to $dest"
else
  kv_write "$GB_STATE/report-upload.status" "result=failed" "time=$(date +%s)"
  log "WARN report: upload of $NAME to $dest failed (see above); retried after the next hourly backup"
fi
exit 0
