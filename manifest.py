#!/usr/bin/env python3
"""Walk the backup paths applying (approximately) the same excludes as restic and print a JSON
manifest: files, bytes, newest_mtime. Used by the stale-computer guard and for size estimates.
Usage: manifest.py --exclude-file FILE [--venvs 0|1] [--cachedirs 0|1] [--ignore-newest DIR]...
                   [--top N] [--explain] PATH..."""
import argparse, fnmatch, json, os, time

ap = argparse.ArgumentParser()
ap.add_argument('--exclude-file', required=True)
ap.add_argument('--venvs', default='0')
ap.add_argument('--cachedirs', default='0')
ap.add_argument('--ignore-newest', action='append', default=[],
                help='files under these dirs do not count for newest_mtime (they change by themselves)')
ap.add_argument('--top', type=int, default=0)
ap.add_argument('--explain', action='store_true')
ap.add_argument('roots', nargs='+')
a = ap.parse_args()

pats = []
for line in open(a.exclude_file):
    line = line.rstrip('\n')
    if line.strip() and not line.lstrip().startswith('#'):
        pats.append(line)
absp = [p for p in pats if p.startswith('/')]
namep = [p.lstrip('*/') if p.startswith('**/') else p for p in pats if not p.startswith('/')]
ignore = [os.path.abspath(d).rstrip('/') + '/' for d in a.ignore_newest]


def excluded(path, name):
    for p in namep:
        if fnmatch.fnmatchcase(name, p):
            return p
    for p in absp:
        if fnmatch.fnmatchcase(path, p) or fnmatch.fnmatchcase(path, p.replace('/**/', '/')):
            return p
        if path.startswith(p.rstrip('/') + '/') and not any(c in p for c in '*?['):
            return p
    return None


tot = {'files': 0, 'bytes': 0, 'newest_mtime': 0}
per = {}
why = {}


def add_why(k, path):
    try:
        s = 0
        if os.path.isdir(path) and not os.path.islink(path):
            for dp, _dn, fn in os.walk(path):
                for f in fn:
                    try:
                        s += os.lstat(os.path.join(dp, f)).st_blocks * 512
                    except OSError:
                        pass
        else:
            s = os.lstat(path).st_blocks * 512
        why[k] = why.get(k, 0) + s
    except OSError:
        pass


def walk(d, top):
    try:
        it = list(os.scandir(d))
    except OSError:
        return
    names = {e.name for e in it}
    if d != top and ((a.venvs == '1' and 'pyvenv.cfg' in names) or (a.cachedirs == '1' and 'CACHEDIR.TAG' in names)):
        if a.explain:
            add_why('venv (pyvenv.cfg)' if 'pyvenv.cfg' in names else 'CACHEDIR.TAG', d)
        return
    for e in it:
        p = e.path
        r = excluded(p, e.name)
        if r:
            if a.explain:
                add_why(r, p)
            continue
        try:
            if e.is_dir(follow_symlinks=False):
                if os.path.ismount(p):
                    continue
                walk(p, top)
            else:
                st = e.stat(follow_symlinks=False)
                tot['files'] += 1
                tot['bytes'] += st.st_size
                if st.st_mtime > tot['newest_mtime'] and st.st_mtime < time.time() + 3600 \
                        and not any(os.path.abspath(p).startswith(i) for i in ignore):
                    tot['newest_mtime'] = int(st.st_mtime)
                k = '/'.join(p.split('/')[:3])
                per[k] = per.get(k, 0) + st.st_size
        except OSError:
            pass


for r in a.roots:
    if os.path.isdir(r):
        walk(r, r)
out = dict(tot, roots=a.roots, at=int(time.time()))
if a.top:
    out['top'] = dict(sorted(per.items(), key=lambda x: -x[1])[:a.top])
if a.explain:
    out['excluded_bytes'] = dict(sorted(why.items(), key=lambda x: -x[1]))
print(json.dumps(out, indent=1 if (a.top or a.explain) else None))
