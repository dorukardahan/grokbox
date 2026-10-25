#!/usr/bin/env bash
# Expected-bot roster (EXPECTED_BOTS in config.env: bot names or agent ids; keep real names in the local
# config.env only). Checks the latest server-side export (staging/server-export/state/positions.json, written by
# server-export-merge.py): every listed bot must be there, readable, and checked within EXPECTED_BOTS_MAX_HOURS.
#   expected-bots.sh           print one line; exit 0 = all present (or no roster configured),
#                              1 = some missing / not readable / stale, 2 = no export yet
#   expected-bots.sh --alert   same, and raise an alert when bots are missing (deduped: once per incident)
# scheduler.sh runs it with --alert after every hourly backup; doctor.sh shows the line.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
ALERT=0
for a in "$@"; do case "$a" in --alert) ALERT=1;; -h|--help) sed -n 2,8p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
if (( ${#EXPECTED_BOTS[@]} == 0 )); then echo "no roster configured (EXPECTED_BOTS is empty)"; exit 0; fi
POS="${SERVER_EXPORT_DIR:-$GB_DIR/staging/server-export}/state/positions.json"
if [[ ! -s "$POS" ]]; then echo "no server-side export yet (${#EXPECTED_BOTS[@]} expected bots unverified; the bots' routines write it)"; exit 2; fi
out=$(python3 - "$POS" "${EXPECTED_BOTS_MAX_HOURS:-26}" "${EXPECTED_BOTS[@]}" <<'PY'
import json, re, sys, time, unicodedata
from datetime import datetime
pos_file, max_h, want = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
try: pos = json.load(open(pos_file, encoding="utf-8"))
except (OSError, ValueError): print("server export state unreadable (positions.json garbled)"); sys.exit(1)
def slug(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
def age_h(c):
    try: return (time.time() - datetime.strptime(c, "%Y-%m-%d %H:%M:%S%z").timestamp()) / 3600
    except (TypeError, ValueError): return None
missing, newest = [], None
for e in want:
    rec = next((r for tid, r in pos.items() if tid == e or (r.get("name") or "").lower() == e.lower() or slug(r.get("name")) == slug(e)), None)
    if rec is None: missing.append(f"{e} (never exported)"); continue
    if rec.get("unreadable"): missing.append(f"{e} (not readable)"); continue
    h = age_h(rec.get("checked"))
    if h is None or h > max_h: missing.append(f"{e} (last export check {'unknown' if h is None else f'{h:.0f} h ago'})"); continue
    newest = h if newest is None else min(newest, h)
if missing:
    print(f"missing from the server-side export: {', '.join(missing)}; present: {len(want) - len(missing)} of {len(want)}"); sys.exit(1)
print(f"all {len(want)} expected bots present in the server-side export (newest check {newest:.0f} h ago)")
PY
); rc=$?
echo "$out"
if (( rc == 1 && ALERT == 1 )); then alert "expected bots $out (EXPECTED_BOTS in config.env; see docs/health-and-alerts.md)"; fi
exit "$rc"
