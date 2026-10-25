#!/usr/bin/env python3
"""Summarize restic's JSON stream without treating unknown errors as harmless."""
import json
import os
import sys

stream, previous = sys.argv[1:]
summary, errors, malformed = {}, [], False
with open(stream) as source:
    for line in source:
        try:
            entry = json.loads(line)
        except ValueError:
            malformed |= line.lstrip().startswith(('{', '['))
            continue
        if not isinstance(entry, dict):
            malformed = True
            continue
        if entry.get('message_type') == 'summary':
            summary = entry
        if entry.get('message_type') == 'error':
            errors.append(entry)
paths = sorted(set(e.get('item', '') for e in errors))
only_unreadable = bool(errors) and not malformed and all(
    e.get('during') == 'archival' and os.path.isfile(e.get('item', '')) and
    'permission denied' in str(e.get('error', {}).get('message', '')).lower()
    for e in errors)
try:
    known = json.load(open(previous))
except (OSError, ValueError):
    known = []
# First omission is incomplete. Repeated, precisely identified unreadable regular files
# are complete-with-warnings; directory traversal and repository errors never qualify.
warnings = only_unreadable and paths == known and bool(summary.get('snapshot_id'))
with open(previous + '.tmp', 'w') as dest:
    json.dump(paths if only_unreadable else [], dest)
os.replace(previous + '.tmp', previous)
print('warnings' if warnings else 'normal')
print(summary.get('snapshot_id', ''))
for key in ('total_files_processed', 'total_bytes_processed', 'data_added_packed'):
    print(int(summary.get(key, 0)))
print(len(paths))
# Escape control characters in filenames to prevent forged alert lines.
print('; '.join(json.dumps(p, ensure_ascii=True) for p in paths[:20]))
