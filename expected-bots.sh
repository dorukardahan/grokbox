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
# Deleted ids (DELETED_BOTS_FILE) and RETIRED_BOTS names/ids are exempt; retained history is reported.
# AGENTS_DIR profiles detect same-name replacements that have never been exported.
# scheduler.sh runs it with --alert after every hourly backup; doctor.sh shows the line.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
ALERT=0
for a in "$@"; do case "$a" in --alert) ALERT=1;; -h|--help) sed -n 2,14p "$0"; exit 0;; *) echo "unknown arg $a" >&2; exit 2;; esac; done
if (( ${#EXPECTED_BOTS[@]} == 0 )); then echo "no roster configured (EXPECTED_BOTS is empty)"; exit 0; fi
POS="${SERVER_EXPORT_DIR:-$GB_DIR/staging/server-export}/state/positions.json"
MAX_H="${EXPECTED_BOTS_MAX_HOURS:-26}"
# prints 2 lines: the status line (with ages) and a stable alert summary (no ages/counts that grow by the hour)
out=$(python3 - "$POS" "$MAX_H" "${EXPECTED_BOTS_GRACE_MIN:-60}" "$DELETED_BOTS_FILE" "$AGENTS_DIR" "${#RETIRED_BOTS[@]}" "${RETIRED_BOTS[@]}" "${EXPECTED_BOTS[@]}" <<'PY'
import json, os, re, sys, time, unicodedata
from datetime import datetime
pos_file, max_h, grace_min = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
deleted_file, agents_dir, retired_n = sys.argv[4], sys.argv[5], int(sys.argv[6])
retired, want = sys.argv[7:7 + retired_n], sys.argv[7 + retired_n:]
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
no_export = not os.path.exists(pos_file) or os.path.getsize(pos_file) == 0
try:
    pos = {} if no_export else json.load(open(pos_file, encoding="utf-8"))
    assert isinstance(pos, dict)
except (OSError, ValueError, AssertionError): print("server export state unreadable (positions.json garbled)\nserver export state unreadable"); sys.exit(1)
def slug(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
def age_h(c):
    try: return (time.time() - datetime.strptime(c, "%Y-%m-%d %H:%M:%S%z").timestamp()) / 3600
    except (TypeError, ValueError): return None
def as_int(v, d):
    return v if isinstance(v, int) and not isinstance(v, bool) else d
def matches(a, b):
    return bool(a and b and (a.lower() == b.lower() or (slug(a) and slug(b) and slug(a) == slug(b))))
def is_deleted(e, tid, rec):
    names = [e, tid] + ([rec.get("name")] if rec else [])
    return tid in deleted_ids or any(matches(n, r) for n in names for r in retired)
# An unavailable inventory is optional; invalid profiles still leave an id-only entry.
inventory = {}
try:
    with os.scandir(agents_dir) as entries:
        for entry in entries:
            try:
                if not entry.is_dir(): continue
            except OSError: continue
            name = None
            try:
                with open(os.path.join(entry.path, "profile.json"), encoding="utf-8") as f:
                    profile = json.load(f)
                if isinstance(profile, dict) and isinstance(profile.get("name"), str):
                    name = profile["name"]
            except (OSError, ValueError): pass
            inventory[entry.name] = {"name": name}
except OSError: inventory = {}
def deleted_status(e, tid, rec):
    total = as_int(rec.get("total"), 0) if rec else 0
    M = as_int(rec.get("max_pos"), -1) if rec else -1
    kept = max(0, M + 1)
    if total > 0: kept = min(total, kept)
    incomplete = M < total - 1 or bool(rec and rec.get("pending"))
    status = (f"history kept ({kept} messages, no longer readable)" if kept and (not total or rec.get("unreadable")) else
              "never exported" if not rec or not total else
              f"nothing exported (0 of {total} messages)" if not kept else
              f"history kept ({kept} of {total} messages, export incomplete)" if incomplete else
              f"history kept ({kept} messages)")
    name = (rec.get("name") or e) if rec else e
    label = name if name.endswith(" (deleted)") else name + " (deleted)"
    if e == tid and e != name: label += f" [{e[:8]}]"
    return f"{label}: {status}"
missing, stable, progress, deleted, newest = [], [], [], [], None
active = 0
for e in want:
    candidates = [(tid, r) for tid, r in pos.items() if isinstance(r, dict) and
                  ((e and tid == e) or matches(r.get("name"), e))]
    tid, rec = next(((tid, r) for tid, r in candidates if not is_deleted(e, tid, r)),
                    candidates[0] if candidates else (e, None))
    if not candidates or is_deleted(e, tid, rec):
        replacement = next(((i, profile) for i, profile in inventory.items()
                            if (i == e or matches(profile.get("name"), e))
                            and not is_deleted(e, i, profile)
                            and not is_deleted(e, i, pos.get(i) if isinstance(pos.get(i), dict) else None)), None)
        if replacement:
            if is_deleted(e, tid, rec): deleted.append(deleted_status(e, tid, rec))
            tid = replacement[0]
            rec = pos.get(tid) if isinstance(pos.get(tid), dict) else None
    if is_deleted(e, tid, rec):
        deleted.append(deleted_status(e, tid, rec)); continue
    active += 1
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
suffix = f"; deleted: {', '.join(deleted)}" if deleted else ""
if not active:
    print(f"no active expected bots{suffix}\n-"); sys.exit(0)
if no_export:
    print(f"no server-side export yet ({active} expected bots unverified; the bots' routines write staging/server-export){suffix}\n{active}"); sys.exit(2)
if missing:
    print(f"missing from the server-side export: {', '.join(missing)}; present: {active - len(missing) - len(progress)} of {active}"
          + (f"; export in progress: {', '.join(progress)}" if progress else "") + suffix)
    print(f"missing from the server-side export: {', '.join(stable)}"); sys.exit(1)
if progress:
    print(f"{active - len(progress)} of {active} expected bots present, export still in progress (gap younger than {grace_min:.0f} min): {', '.join(progress)}{suffix}\n-"); sys.exit(0)
age = f" (newest check {newest:.0f} h ago)" if newest is not None else ""
print(f"all {active} expected bots present and complete in the server-side export{age}{suffix}\n-")
PY
); rc=$?
echo "${out%%$'\n'*}"
if (( rc == 1 && ALERT == 1 )); then alert "expected bots ${out#*$'\n'} (EXPECTED_BOTS in config.env; see docs/health-and-alerts.md)"; fi
if (( rc == 2 )); then
  # bounded installation grace for active bots only
  first=$(epoch_file "$GB_STATE/first-start")
  if (( ALERT == 1 )) && { [[ -z "$first" ]] || (( $(date +%s) - first >= MAX_H * 3600 )); }; then
    alert "expected bots: no server-side export at all (${out#*$'\n'} expected bots unverified, more than EXPECTED_BOTS_MAX_HOURS=$MAX_H h after the first start); check that the GrokBox-Main/Assist routines run (docs/bots.md)"
  fi
fi
exit "$rc"
