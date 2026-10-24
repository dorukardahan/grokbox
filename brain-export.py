#!/usr/bin/env python3
"""Generic "brain" export: make everything that identifies the agent(s) on this box easy to find and
sure to be in every snapshot.

  - Agent data directories (BRAIN_AGENT_DIRS, e.g. /home/box/agent-data) are indexed. They normally
    live inside the backup roots and are backed up in place; a directory OUTSIDE the roots is copied.
  - Mounted agent stores (STORES_GLOB, e.g. /cursor/stores/*) usually live OUTSIDE the roots, so they
    are mirrored into STAGING/brain/stores/<name>/ (only when readable and non-empty right now, so a
    temporarily unmounted store never wipes the staged copy). Databases that the SQLite step staged
    successfully this run (--staged-list) are skipped here; every other file, .db/.sqlite included,
    is copied as-is.
  - STAGING/brain/INDEX.md lists what was found.
Every path may be missing; the script then just reports "none".

Usage: brain-export.py STAGING_DIR [--min-interval-min N] [--stores-glob GLOB] [--agent-dir DIR]...
                       [--root DIR]... [--max-file-mb N] [--staged-list FILE] [--force]"""
import argparse, glob, os, shutil, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('staging')
ap.add_argument('--min-interval-min', type=int, default=55)
ap.add_argument('--stores-glob', default='/cursor/stores/*')
ap.add_argument('--agent-dir', action='append', default=[])
ap.add_argument('--root', action='append', default=[], help='backup roots (dirs under them are not copied)')
ap.add_argument('--max-file-mb', type=int, default=256)
ap.add_argument('--staged-list', help='file with absolute paths of DBs staged by sqlite-snapshot this run')
ap.add_argument('--force', action='store_true')
a = ap.parse_args()

DST = os.path.join(a.staging, 'brain')
stamp = os.path.join(DST, '.exported-at')
if not a.force and os.path.exists(stamp) and time.time() - os.path.getmtime(stamp) < a.min_interval_min * 60:
    print('brain export: fresh enough, skip', file=sys.stderr)
    sys.exit(0)
SKIP_EXT = ('.lock', '.tmp')
STAGED = set()
if a.staged_list and os.path.exists(a.staged_list):
    with open(a.staged_list) as _f:
        for _l in _f:
            if _l.strip():
                STAGED.add(os.path.abspath(_l.strip()))
STAGED |= {p + x for p in set(STAGED) for x in ('-wal', '-shm', '-journal')}


def skipped(p):
    return p.endswith(SKIP_EXT) or os.path.abspath(p) in STAGED
MAX = a.max_file_mb * 2 ** 20
copied, warns, skipped_big = 0, [], []
roots = [os.path.abspath(r).rstrip('/') + '/' for r in a.root]


def under_roots(p):
    p = os.path.abspath(p).rstrip('/') + '/'
    return any(p.startswith(r) for r in roots)


PWFILE = os.environ.get('RESTIC_PASSWORD_FILE')


def is_secret_key(p):
    """The restic repository password must never be copied (any file named restic-pass, or the configured one)."""
    if os.path.basename(p) == 'restic-pass':
        return True
    try:
        return bool(PWFILE) and os.path.exists(PWFILE) and os.path.samefile(p, PWFILE)
    except OSError:
        return False


def sync(src, dst):
    """Mirror src -> dst; changed files are copied, vanished files are removed from the mirror."""
    global copied
    if os.path.isfile(src):
        if skipped(src) or is_secret_key(src):
            return
        try:
            s = os.stat(src)
            if s.st_size > MAX:
                skipped_big.append(src)
                return
            if not (os.path.exists(dst) and os.path.getsize(dst) == s.st_size and int(os.path.getmtime(dst)) == int(s.st_mtime)):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst + '.tmp')
                os.replace(dst + '.tmp', dst)
                copied += 1
        except OSError as e:
            warns.append(f'{src}: {e}')
        return
    if not os.path.isdir(src):
        return
    keep = set()
    try:
        entries = list(os.scandir(src))
    except OSError as e:
        warns.append(f'{src}: {e}')
        return
    for e in entries:
        if e.is_symlink() or skipped(e.path) or (not e.is_dir() and is_secret_key(e.path)):
            continue
        keep.add(e.name)
        sync(e.path, os.path.join(dst, e.name))
    if os.path.isdir(dst):
        for n in os.listdir(dst):
            if n not in keep and not n.endswith('.tmp'):
                p = os.path.join(dst, n)
                shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)


def summarize(d):
    files = size = 0
    newest = 0
    dbs = []
    for dp, _dn, fn in os.walk(d):
        for f in fn:
            p = os.path.join(dp, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            files += 1
            size += st.st_size
            newest = max(newest, int(st.st_mtime))
            if f.endswith(('.db', '.sqlite')):
                dbs.append(p)
    return files, size, newest, dbs


def fmt(ts):
    return time.strftime('%Y-%m-%d %H:%M %Z', time.localtime(ts)) if ts else 'n/a'


os.makedirs(DST, exist_ok=True)
lines = [f'# Brain export index - {time.strftime("%Y-%m-%d %H:%M %Z")}', '',
         'Generated by brain-export.py. Agent data directories inside the backup roots are backed up in',
         'place; stores outside the roots are mirrored below `stores/`. Live SQLite databases are staged',
         'as consistent copies under `../sqlite/<original path>`.', '', '## Agent data directories']
found_agent = False
for d in a.agent_dir:
    if not os.path.isdir(d):
        continue
    found_agent = True
    files, size, newest, dbs = summarize(d)
    inside = under_roots(d)
    lines.append(f'### `{d}` - {"inside the backup roots (backed up in place)" if inside else "OUTSIDE the roots (copied to brain/agent-data)"}')
    lines.append(f'- {files} files, {size / 1e6:.1f} MB, newest {fmt(newest)}')
    try:
        top = sorted(os.listdir(d))
    except OSError:
        top = []
    lines.append('- top level: ' + (', '.join(top[:40]) + (' ...' if len(top) > 40 else '') if top else '(empty)'))
    if dbs:
        lines.append(f'- SQLite databases: {len(dbs)} (consistent copies staged when they match SQLITE_GLOBS)')
    lines.append('')
    if not inside:
        sync(d, os.path.join(DST, 'agent-data', d.strip('/').replace('/', '_')))
if not found_agent:
    lines += ['- none found', '']
lines.append('## Mounted agent stores')
stores = sorted(glob.glob(a.stores_glob))
if not stores:
    lines.append('- none found')
for st in stores:
    try:
        has = any(True for _ in os.scandir(st))
    except OSError as e:
        warns.append(f'{st}: {e}')
        lines.append(f'- `{st}`: unreadable now ({e.__class__.__name__})')
        continue
    if not has:
        lines.append(f'- `{st}`: empty/unmounted now, not copied')
        continue
    if under_roots(st):
        lines.append(f'- `{st}`: inside the backup roots, backed up in place')
        continue
    sync(st, os.path.join(DST, 'stores', os.path.basename(st.rstrip('/'))))
    files, size, newest, _ = summarize(st)
    lines.append(f'- `{st}`: {files} files, {size / 1e6:.1f} MB, newest {fmt(newest)} -> copied to brain/stores/{os.path.basename(st.rstrip("/"))}')
if skipped_big:
    lines += ['', f'## Not copied (larger than {a.max_file_mb} MB)'] + [f'- `{p}`' for p in skipped_big[:50]]
lines.append('')
with open(os.path.join(DST, 'INDEX.md'), 'w') as f:
    f.write('\n'.join(lines))
with open(stamp, 'w') as f:
    f.write(str(int(time.time())))
for w in warns[:20]:
    print('WARN brain export:', w, file=sys.stderr)
print(f'brain export: {copied} files updated, {len(stores)} stores, warnings {len(warns)}', file=sys.stderr)
sys.exit(1 if len(warns) > 50 else 0)
