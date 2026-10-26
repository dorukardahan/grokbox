#!/usr/bin/env bash
# Daily export freshness: did any active bot receive a recent per-bot export check?
#   export-freshness.sh          exit 0 = recent / disabled / no active bots, 1 = missed / garbled,
#                               2 = no server-side export yet
#   export-freshness.sh --alert  raise a stable, deduped alert (first-start grace for no export)
# Deleted ids, RETIRED_BOTS names/ids and unreadable records are ignored.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
ALERT=0
for a in "$@"; do case "$a" in --alert) ALERT=1;; -h|--help) sed -n 2,6p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
MAX_H="$EXPORT_MISSED_HOURS"
if [[ "$MAX_H" == 0 ]]; then echo "daily export check disabled"; exit 0; fi
POS="${SERVER_EXPORT_DIR:-$GB_DIR/staging/server-export}/state/positions.json"
out=$(python3 - "$POS" "$MAX_H" "$DELETED_BOTS_FILE" "${RETIRED_BOTS[@]}" <<'PYTHON'
import json, os, re, sys, time, unicodedata
from datetime import datetime
pos_file, max_h, deleted_file = sys.argv[1], float(sys.argv[2]), sys.argv[3]
retired = sys.argv[4:]
# Keep tolerant parsing identical to server-export-merge.py: deleted_ids().
deleted_ids = set()
try:
    with open(deleted_file, encoding="utf-8") as f: entries = json.load(f)
    if isinstance(entries, dict):
        entries = entries["agents"] if "agents" in entries else {k: v for k, v in entries.items() if isinstance(v, dict)}
    if isinstance(entries, dict): deleted_ids = set(entries)
    elif isinstance(entries, list):
        for entry in entries:
            tid = entry.get("id") if isinstance(entry, dict) else entry
            if isinstance(tid, str): deleted_ids.add(tid)
except (OSError, ValueError): pass
try:
    if not os.path.exists(pos_file) or os.path.getsize(pos_file) == 0:
        print("no server-side export yet"); sys.exit(2)
    with open(pos_file, encoding="utf-8") as f: pos = json.load(f)
    assert isinstance(pos, dict)
except (OSError, ValueError, AssertionError):
    print("server export state unreadable (positions.json garbled)"); sys.exit(1)
if not pos:
    print("no server-side export yet"); sys.exit(2)
def slug(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
def matches(a, b):
    return bool(a and b and (a.lower() == b.lower() or (slug(a) and slug(b) and slug(a) == slug(b))))
active, checks = 0, []
for tid, rec in pos.items():
    if not isinstance(rec, dict) or rec.get("unreadable") is True or rec.get("deleted") is True: continue
    name = rec.get("name") if isinstance(rec.get("name"), str) else ""
    if tid in deleted_ids or any(matches(n, r) for n in (tid, name) for r in retired): continue
    active += 1
    try: checks.append(datetime.strptime(rec.get("checked"), "%Y-%m-%d %H:%M:%S%z").timestamp())
    except (TypeError, ValueError): pass
if not active:
    print("daily export: no active exported bots"); sys.exit(0)
if not checks:
    print("server export state unreadable (positions.json garbled)"); sys.exit(1)
h = (time.time() - max(checks)) / 3600
if h <= max_h:
    print(f"daily export OK (newest per-bot export check {h:.0f} h ago)"); sys.exit(0)
print(f"daily export missed: no bot was exported in the last {max_h:g} h (newest per-bot export check {h:.0f} h ago); "
      "the scheduled routine hands the export to the bot's chat - run the export loop (docs/routine-main.md)")
sys.exit(1)
PYTHON
); rc=$?
if [[ -z "$out" ]]; then out="daily export check failed"; rc=1; fi
echo "$out"
if (( ALERT == 1 )); then
  if [[ "$out" == "daily export check failed" ]]; then
    alert "$out"
  elif (( rc == 1 )) && [[ "$out" == 'server export state unreadable'* ]]; then
    alert "server export state unreadable (positions.json garbled)"
  elif (( rc == 1 || rc == 2 )); then
    first=$(epoch_file "$GB_STATE/first-start")
    if (( rc == 1 )) || [[ -z "$first" ]] || (( $(date +%s) - first >= MAX_H * 3600 )); then
      alert "daily export missed: no per-bot export check in the last EXPORT_MISSED_HOURS=$MAX_H h; run the export loop in GrokBox-Main's chat (docs/routine-main.md)"
    fi
  fi
fi
exit "$rc"
