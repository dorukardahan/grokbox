#!/usr/bin/env bash
# Writes state/latest-backup-report.txt (plain text, human readable, in $TZ: last backup time/result/size/files/
# added/duration, repository size, last check + prune, last test restore) and, for rclone: repositories with
# DRIVE_REPORT=1, uploads it into the PARENT of GB_FOLDER (e.g. GrokBox/restic -> GrokBox/latest-backup-report.txt,
# never inside restic/). scheduler.sh runs it after every hourly backup, daily check and test restore.
# The report holds no secrets, paths, snapshot ids or e-mail addresses (only BACKUP_HOST). `rclone copyto` replaces
# the file in place. Runs are serialized by state/report.lock and use private scratch files, so two invocations can
# never mix their inputs or upload a half-written file. A failure never fails anything else: it is written to
# state/report-upload.status (result=ok|failed, time, stage=build|upload) and shown by status.sh and doctor.sh.
#   report.sh               write + upload        report.sh --no-upload   write only
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
R_TIMEOUT=300   # the report must never hold things up: short, tolerant restic calls
UPLOAD=1
for a in "$@"; do case "$a" in --no-upload) UPLOAD=0;; -h|--help) sed -n 2,10p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
OUT="$GB_STATE/latest-backup-report.txt"; NAME="latest-backup-report.txt"; STATUS="$GB_STATE/report-upload.status"
exec 6>>"$GB_STATE/report.lock"
flock -w "${REPORT_LOCK_WAIT:-120}" 6 || { log "report: another report.sh still runs; this run skipped"; exit 0; }
W=$(mktemp -d "$GB_STATE/report.XXXXXX") || { log "WARN report: cannot create a scratch dir in $GB_STATE"; exit 0; }
trap 'rm -rf "$W"' EXIT
SNAP="$W/snapshot.json"; STATS="$W/stats.json"
if [[ -s "$RESTIC_PASSWORD_FILE" ]] && { ! is_rclone_repo || [[ -s "$RCLONE_CONFIG" ]]; }; then
  # newest hourly snapshot (its summary carries files/bytes/added/duration) + raw repository size; both optional
  R snapshots --no-lock --host "$BACKUP_HOST" --tag auto --latest 1 --json > "$SNAP.tmp" 2>/dev/null && mv "$SNAP.tmp" "$SNAP"
  R stats --no-lock --mode raw-data --json > "$STATS.tmp" 2>/dev/null && mv "$STATS.tmp" "$STATS"
fi
nalerts=0; [[ -s "$GB_STATE/ALERT" ]] && nalerts=$(wc -l < "$GB_STATE/ALERT")
python3 - "$GB_STATE" "$SNAP" "$STATS" "$BACKUP_HOST" "$nalerts" "${TEST_RESTORE_WEEKDAY:-}" > "$W/report.txt" <<'PY'
import json, os, re, sys, time
st, snapf, statsf, host, nalerts, weekday = sys.argv[1:7]
# Shared state files are read defensively: numbers must be bounded plain integers, epochs plausible (< year 2242);
# anything else is "unknown". No float parsing (1e9999), no unbounded ints (localtime overflow).
def kv(name):
    d = {}
    try:
        for l in open(os.path.join(st, name), encoding="utf-8", errors="replace"):
            if "=" in l: k, v = l.rstrip("\n").split("=", 1); d[k.strip()] = v.strip()
    except OSError: pass
    return d
def num(v):
    v = (v or "").strip() if isinstance(v, str) else v
    if isinstance(v, bool): return None
    if isinstance(v, int): return v if 0 <= v < 10**15 else None
    if isinstance(v, float): return int(v) if 0 <= v < 10**15 else None
    return int(v) if isinstance(v, str) and v.isdigit() and len(v) <= 15 else None
def epoch(v):
    t = num(v); return t if t is not None and 0 < t < 2**33 else None
def epoch_file(name):
    try: return epoch(open(os.path.join(st, name)).read(64).strip())
    except OSError: return None
def ts(t, none="never"):
    if t is None: return none
    try: return time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(t))
    except (OverflowError, OSError, ValueError): return "unknown"
def size(b):
    if b is None: return "unknown"
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or u == "TB": return f"{b:.0f} {u}" if u == "B" else f"{b:.1f} {u}"
        b /= 1024
def dur(s):
    if s is None: return "unknown"
    return f"{s // 3600} h {s % 3600 // 60} min" if s >= 3600 else (f"{s // 60} min {s % 60} s" if s >= 60 else f"{s} s")
def iso(t):
    from datetime import datetime
    return int(datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", t).replace("Z", "+00:00")).timestamp())
lb = kv("last-backup.result")                      # written by backup.sh (may be absent on older versions)
t_ok, t_part = epoch_file("last-success"), epoch_file("last-partial")
snap = {}
try:
    s = json.load(open(snapf)); snap = sorted(s, key=lambda x: x.get("time", ""))[-1] if s else {}
    if not isinstance(snap, dict): snap = {}
except (OSError, ValueError, TypeError, AttributeError): pass
sm = snap.get("summary") if isinstance(snap.get("summary"), dict) else {}
result = lb.get("result"); when = epoch(lb.get("time"))
legacy = result not in ("complete", "incomplete", "failed", "timeout")
if legacy:   # no usable last-backup.result: fall back to the classic state files + the newest snapshot's summary
    if t_ok or t_part:
        result = "incomplete" if (t_part or 0) >= (t_ok or 0) else "complete"; when = max(t_ok or 0, t_part or 0)
    else: result, when = "no backup yet", None
# The snapshot summary may only stand in for missing values when it belongs to the reported run (the run's own
# snapshot id is a prefix of the newest snapshot's id) or in the legacy fallback. A valid 0 is never replaced.
sid = lb.get("snapshot", "") if not legacy else ""
same_run = legacy or (bool(re.fullmatch(r"[0-9a-f]{4,64}", sid)) and str(snap.get("id", "")).startswith(sid))
def pick(key, sm_value):
    v = num(lb.get(key)) if not legacy else None
    return v if v is not None else (num(sm_value) if same_run else None)
def snap_dur():
    try: return iso(sm["backup_end"]) - iso(sm["backup_start"])
    except (KeyError, TypeError, ValueError): return None
files = pick("files", sm.get("total_files_processed"))
tbytes = pick("bytes", sm.get("total_bytes_processed"))
added = pick("added", sm.get("data_added_packed", sm.get("data_added")))
dur_s = pick("duration_s", snap_dur())
unread = num(lb.get("unreadable")) if not legacy else None
try: repo = size(num(json.load(open(statsf)).get("total_size")))
except (OSError, ValueError, AttributeError): repo = "unknown"
lc = kv("last-check.result"); c_t = epoch(lc.get("time")) or epoch_file("last-check")
c_res = lc.get("result") if lc.get("result") in ("ok", "failed", "skipped") else ("ok" if c_t else "never")
pruned = {"1": "yes", "0": "no"}.get(lc.get("pruned", ""), "unknown")
if os.path.exists(os.path.join(st, "CHECK_FAILED")): c_res = "FAILED (prune blocked until a check passes)"
tr = kv("test-restore.result"); tr_t = epoch(tr.get("time")) or epoch_file("last-test-restore")
tr_res = tr.get("result") if tr.get("result") in ("ok", "failed") else ("ok" if tr_t else "never")
tr_f, tr_m = num(tr.get("files")), num(tr.get("mismatches"))
L = [f"Grok Box backup report (host {host})", f"Written:            {ts(int(time.time()))}", ""]
L += [f"Last backup:        {ts(when, 'unknown' if result != 'no backup yet' else 'never')}",
      f"Result:             {result}" + (f" ({unread} unreadable file(s))" if unread else "")]
L += [f"Files:              {files:,}" if files is not None else "Files:              unknown",
      f"Source size:        {size(tbytes)}", f"Added this run:     {size(added)}", f"Duration:           {dur(dur_s)}",
      f"Repository size:    {repo}", "",
      f"Last check:         {ts(c_t)}, result: {c_res}, prune: {pruned}",
      f"Last test restore:  {ts(tr_t)}, result: {tr_res}" + (f" ({tr_f} files, {tr_m if tr_m is not None else '?'} mismatches)" if tr_f is not None else ""),
      f"Open alerts:        {nalerts}", "",
      "Schedule: hourly snapshot, quick snapshots in between, daily forget + prune + check, "
      + ("weekly test restore." if weekday else "monthly test restore."),
      "This file is rewritten after every hourly backup; the restic repository itself is in the restic/ folder next to it."]
print("\n".join(L))
PY
rc=$?
if (( rc != 0 )); then
  kv_write "$STATUS" "result=failed" "time=$(date +%s)" "stage=build"
  log "WARN report: could not build $NAME (python rc=$rc); recorded in state/report-upload.status"; exit 0
fi
mv "$W/report.txt" "$OUT"   # atomic replace of the local copy (same filesystem)
[[ $UPLOAD == 1 ]] || exit 0
if [[ "${DRIVE_REPORT:-1}" != 1 ]]; then log "report: DRIVE_REPORT=0, $NAME written locally only"; exit 0; fi
if ! is_rclone_repo; then log "report: not an rclone: repository, $NAME written locally only"; exit 0; fi
folder="${GB_FOLDER%/}"
if [[ "$folder" != */* ]]; then log "report: GB_FOLDER '$GB_FOLDER' has no parent folder; $NAME not uploaded (it never goes inside the restic folder)"; exit 0; fi
dest="$GB_REMOTE:${folder%/*}/$NAME"
if RCL copyto "$OUT" "$dest" >>"$LOG" 2>&1; then
  kv_write "$STATUS" "result=ok" "time=$(date +%s)" "stage=upload"
  log "report: $NAME uploaded to $dest"
else
  kv_write "$STATUS" "result=failed" "time=$(date +%s)" "stage=upload"
  log "WARN report: upload of $NAME to $dest failed (see above); retried after the next hourly backup"
fi
exit 0
