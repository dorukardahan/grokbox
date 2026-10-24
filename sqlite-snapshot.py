#!/usr/bin/env python3
"""Transaction-consistent copies of live SQLite databases (SQLite online-backup API).
Usage: sqlite-snapshot.py STAGING_DIR LIST_FILE GLOB...
Every file matching a GLOB (recursive ** supported) that is a real SQLite database is copied to
STAGING_DIR/sqlite/<original absolute path>. A copy is refreshed unless the stored identity of the
source (dev/inode, size, mtime_ns of the DB and its -wal, kept in LIST_FILE.identity.json) is
unchanged since the copy was made; the identity is taken BEFORE the copy, so a write during the
copy triggers a new copy next run.
LIST_FILE receives (atomically, at the end) only the absolute source paths whose copy is fresh
(lib.sh excludes exactly those live files from the restic run). Exit status is 1 if any database
failed, 0 otherwise (the list is still written). Staged copies whose source vanished are removed, but only when the source's
directory still exists (a temporarily unmounted store never wipes its copies). Missing paths are fine."""
import glob, json, os, sqlite3, sys

staging, listfile, globs = sys.argv[1], sys.argv[2], sys.argv[3:]
base = os.path.join(staging, 'sqlite')
HEADER = b'SQLite format 3\x00'
sources = set()
for g in globs:
    for src in glob.glob(g, recursive=True):
        if os.path.isfile(src) and not os.path.islink(src):
            sources.add(os.path.abspath(src))


def identity(p):
    out = []
    for x in (p, p + '-wal'):
        try:
            st = os.stat(x)
            out.append([st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns])
        except OSError:
            out.append(None)
    return out


def is_sqlite(p):
    try:
        with open(p, 'rb') as f:
            return f.read(16) == HEADER
    except OSError:
        return False


idfile = listfile + '.identity.json'
try:
    with open(idfile) as f:
        known = json.load(f)
except (OSError, ValueError):
    known = {}
ids = {}
staged, n, failed = [], 0, 0
for src in sorted(sources):
    if not is_sqlite(src):
        continue
    dst = os.path.join(base, src.lstrip('/'))
    ident = identity(src)
    if os.path.exists(dst) and known.get(src) == ident:
        staged.append(src)
        ids[src] = ident
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + '.tmp'
    try:
        s = sqlite3.connect(f'file:{src}?mode=ro', uri=True, timeout=30)
        d = sqlite3.connect(tmp)
        s.backup(d)
        d.close()
        s.close()
        os.replace(tmp, dst)
        staged.append(src)
        ids[src] = ident
        n += 1
    except Exception as e:  # noqa: BLE001 - report and continue with the next database
        failed += 1
        print(f'WARN sqlite snapshot failed for {src}: {e}', file=sys.stderr)
        if os.path.exists(tmp):
            os.remove(tmp)
for dp, _dn, fn in os.walk(base):
    for f in fn:
        dst = os.path.join(dp, f)
        if f.endswith('.tmp'):
            continue
        src = '/' + os.path.relpath(dst, base)
        if src not in sources and not os.path.exists(src) and os.path.isdir(os.path.dirname(src)):
            os.remove(dst)
for path, data in ((idfile, json.dumps(ids)), (listfile, ''.join(p + '\n' for p in staged))):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        f.write(data)
    os.replace(tmp, path)
print(f'sqlite snapshots refreshed: {n}, staged total: {len(staged)}, failed: {failed}', file=sys.stderr)
sys.exit(1 if failed else 0)
