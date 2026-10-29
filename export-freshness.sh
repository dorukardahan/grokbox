#!/usr/bin/env bash
# Daily export freshness: did every active bot receive a recent per-bot export check?
#   export-freshness.sh          exit 0 = recent / disabled / no active bots, 1 = missed / garbled,
#                               2 = no server-side export yet
#   export-freshness.sh --alert  raise a stable, deduped alert (first-start grace for no export)
#   export-freshness.sh --warnings  list active bots with INDEX warnings (exit 1; no alerts)
# Deleted ids, RETIRED_BOTS names/ids and unreadable records are ignored.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
ALERT=0; WARNINGS=0
for a in "$@"; do case "$a" in --alert) ALERT=1;; --warnings) WARNINGS=1;; -h|--help) sed -n 2,7p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
MAX_H="$EXPORT_MISSED_HOURS"
if [[ "$MAX_H" == 0 && "$WARNINGS" == 0 ]]; then echo "daily export check disabled"; exit 0; fi
POS="${SERVER_EXPORT_DIR:-$GB_DIR/staging/server-export}/state/positions.json"
out=$(python3 - "$POS" "$MAX_H" "$DELETED_BOTS_FILE" "$WARNINGS" "${RETIRED_BOTS[@]}" <<'PYTHON'
import json, os, re, sys, time, unicodedata
from datetime import datetime
pos_file, max_h, deleted_file = sys.argv[1], float(sys.argv[2]), sys.argv[3]
warnings = sys.argv[4] == "1"
retired = sys.argv[5:]
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
active, warned = [], []
now = time.time()
for tid, rec in pos.items():
    if not isinstance(rec, dict) or rec.get("unreadable") is True or rec.get("deleted") is True: continue
    name = rec.get("name") if isinstance(rec.get("name"), str) else ""
    if tid in deleted_ids or any(matches(n, r) for n in (tid, name) for r in retired): continue
    label = name or tid[:8]
    if rec.get("warnings"): warned.append(label)
    try: h = (now - datetime.strptime(rec.get("checked"), "%Y-%m-%d %H:%M:%S%z").timestamp()) / 3600
    except (TypeError, ValueError): h = float("inf")
    active.append((h, label))
if warnings:
    if warned:
        print(f"export warnings: {len(warned)} active bot(s) with warnings (see staging/server-export/INDEX.md): "
              + ", ".join(sorted(warned)[:5])); sys.exit(1)
    print("no export warnings"); sys.exit(0)
if not active:
    print("daily export: no active exported bots"); sys.exit(0)
stale = sorted(((h, name) for h, name in active if h > max_h), key=lambda item: (-item[0], item[1]))
if not stale:
    print(f"daily export OK (all {len(active)} active bots checked within {max_h:g} h, oldest {max(h for h, _ in active):.0f} h ago)"); sys.exit(0)
oldest = ", ".join(f"{name} {'unknown age' if h == float('inf') else f'{h:.0f} h'}" for h, name in stale[:5])
extra = f", ... +{len(stale) - 5} more" if len(stale) > 5 else ""
print(f"daily export missed: {len(stale)} of {len(active)} active bots were not exported in the last {max_h:g} h (oldest: {oldest}{extra})")
print(f"daily export missed: {len(stale)} of {len(active)} active bots not exported within EXPORT_MISSED_HOURS={max_h:g} h: "
      + ", ".join(sorted(name for _, name in stale)[:5]))
sys.exit(1)
PYTHON
); rc=$?
if [[ -z "$out" ]]; then out="daily export check failed"; rc=1; fi
echo "${out%%$'\n'*}"
if (( ALERT == 1 && WARNINGS == 0 )); then
  if [[ "$out" == "daily export check failed" ]]; then
    alert "$out"
  elif (( rc == 1 )) && [[ "$out" == 'server export state unreadable'* ]]; then
    alert "server export state unreadable (positions.json garbled)"
  elif (( rc == 1 )); then
    alert "${out#*$'\n'}"
  elif (( rc == 2 )); then
    first=$(epoch_file "$GB_STATE/first-start")
    if [[ -z "$first" ]] || (( $(date +%s) - first >= MAX_H * 3600 )); then
      alert "daily export missed: no per-bot export check in the last EXPORT_MISSED_HOURS=$MAX_H h; run the export loop in GrokBox-Main's chat (docs/routine-main.md)"
    fi
  fi
fi
exit "$rc"
