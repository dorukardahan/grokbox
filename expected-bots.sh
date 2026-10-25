#!/usr/bin/env bash
# Expected-bot roster (EXPECTED_BOTS in config.env: bot names or agent ids; keep real names in the local
# config.env only). Checks the latest server-side export (staging/server-export/state/positions.json, written by
# server-export-merge.py). A listed bot counts as present only when it is there, readable, checked within
# EXPECTED_BOTS_MAX_HOURS and its export is COMPLETE by the merger's own rule (max_pos >= total-1 and no pending
# pages; an empty conversation, total 0, is complete). An incomplete export whose last check is younger than
# EXPECTED_BOTS_GRACE_MIN counts as "export in progress" (the routine is still paging), not as missing.
#   expected-bots.sh           print one line; exit 0 = all present / in progress (or no roster configured),
#                              1 = some missing / not readable / stale / incomplete, 2 = no export yet
#   expected-bots.sh --alert   same, and raise an alert (deduped: once per incident) when bots are missing, or
#                              when there is still no export EXPECTED_BOTS_MAX_HOURS after the first start
# scheduler.sh runs it with --alert after every hourly backup; doctor.sh shows the line.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
ALERT=0
for a in "$@"; do case "$a" in --alert) ALERT=1;; -h|--help) sed -n 2,12p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
if (( ${#EXPECTED_BOTS[@]} == 0 )); then echo "no roster configured (EXPECTED_BOTS is empty)"; exit 0; fi
POS="${SERVER_EXPORT_DIR:-$GB_DIR/staging/server-export}/state/positions.json"
MAX_H="${EXPECTED_BOTS_MAX_HOURS:-26}"
if [[ ! -s "$POS" ]]; then
  echo "no server-side export yet (${#EXPECTED_BOTS[@]} expected bots unverified; the bots' routines write staging/server-export)"
  # bounded installation grace: the bots' first export is expected within EXPECTED_BOTS_MAX_HOURS of the first start
  first=$(epoch_file "$GB_STATE/first-start")
  if (( ALERT == 1 )) && { [[ -z "$first" ]] || (( $(date +%s) - first >= MAX_H * 3600 )); }; then
    alert "expected bots: no server-side export at all (${#EXPECTED_BOTS[@]} expected bots unverified, more than EXPECTED_BOTS_MAX_HOURS=$MAX_H h after the first start); check that the GrokBox-Main/Assist routines run (docs/bots.md)"
  fi
  exit 2
fi
# prints 2 lines: the status line (with ages) and a stable alert summary (no ages/counts that grow by the hour)
out=$(python3 - "$POS" "$MAX_H" "${EXPECTED_BOTS_GRACE_MIN:-60}" "${EXPECTED_BOTS[@]}" <<'PY'
import json, re, sys, time, unicodedata
from datetime import datetime
pos_file, max_h, grace_min, want = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4:]
try: pos = json.load(open(pos_file, encoding="utf-8")); assert isinstance(pos, dict)
except (OSError, ValueError, AssertionError): print("server export state unreadable (positions.json garbled)\nserver export state unreadable"); sys.exit(1)
def slug(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
def age_h(c):
    try: return (time.time() - datetime.strptime(c, "%Y-%m-%d %H:%M:%S%z").timestamp()) / 3600
    except (TypeError, ValueError): return None
def as_int(v, d):
    return v if isinstance(v, int) and not isinstance(v, bool) else d
missing, stable, progress, newest = [], [], [], None
for e in want:
    rec = next((r for tid, r in pos.items() if isinstance(r, dict) and
                (tid == e or (r.get("name") or "").lower() == e.lower() or slug(r.get("name")) == slug(e))), None)
    if rec is None: missing.append(f"{e} (never exported)"); stable.append(f"{e} (never exported)"); continue
    if rec.get("unreadable"): missing.append(f"{e} (not readable)"); stable.append(f"{e} (not readable)"); continue
    h = age_h(rec.get("checked"))
    if h is None or h > max_h:
        missing.append(f"{e} (last export check {'unknown' if h is None else f'{h:.0f} h ago'})")
        stable.append(f"{e} (last export check {'unknown' if h is None else f'older than {max_h:.0f} h'})"); continue
    total, M, pend = as_int(rec.get("total"), None), as_int(rec.get("max_pos"), -1), rec.get("pending") or []
    complete = total is not None and (total == 0 or (M >= total - 1 and not pend))   # same rule as the merger's INDEX.md
    if not complete:
        why = "export state garbled" if total is None else f"export incomplete: {M + 1} of {total} messages{', pending pages' if pend else ''}"
        if h * 60 < grace_min: progress.append(f"{e} ({why}, checked {h * 60:.0f} min ago)")
        else: missing.append(f"{e} ({why})"); stable.append(f"{e} (export incomplete)")
        continue
    newest = h if newest is None else min(newest, h)
if missing:
    print(f"missing from the server-side export: {', '.join(missing)}; present: {len(want) - len(missing) - len(progress)} of {len(want)}"
          + (f"; export in progress: {', '.join(progress)}" if progress else ""))
    print(f"missing from the server-side export: {', '.join(stable)}"); sys.exit(1)
if progress:
    print(f"{len(want) - len(progress)} of {len(want)} expected bots present, export still in progress (gap younger than {grace_min:.0f} min): {', '.join(progress)}\n-"); sys.exit(0)
print(f"all {len(want)} expected bots present and complete in the server-side export (newest check {newest:.0f} h ago)\n-")
PY
); rc=$?
echo "${out%%$'\n'*}"
if (( rc == 1 && ALERT == 1 )); then alert "expected bots ${out#*$'\n'} (EXPECTED_BOTS in config.env; see docs/health-and-alerts.md)"; fi
exit "$rc"
