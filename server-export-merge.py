#!/usr/bin/env python3
"""Merge ReadTranscript (write_to_file) chunk files into staging/server-export/.

ReadTranscript is a Grok Bot tool, not callable from cron, so the primary bot's daily routine
pulls the pages (in=<id>, limit=200, write_to_file=true, paging back with `before`) and runs:

  server-export-merge.py ingest [--remove] CHUNK...   merge chunks (idempotent; re-ingest is a no-op)
  server-export-merge.py next                         what to call next (JSON): per transcript the
                                                     `before` value still needed, or "newest"; {} = all complete
  server-export-merge.py index                        rewrite INDEX.md
  server-export-merge.py memory [--remove] CHUNK...   merge RecallMemory (write_to_file) results into
                                                     memory/primary-bot-and-shared.md (deduped, kept forever)

Layout (dir 700, files 600):
  transcripts/<id>__<slug>.jsonl   oldest first, one message per line
  state/positions.json             {id: {name, total, max_pos, lines, last_export, ...}}
  state/pending/<id>/<A>-<B>.jsonl pages not yet contiguous with what is exported (a gap remains)
Pages are stitched by the header range "positions A–B of N". A page that overlaps what is already
exported (the incremental case: newest page) is de-duplicated by matching the longest suffix of the
exported file against the page's head (positions and lines are not 1:1: tool results can share a slot).
"""
import json, os, re, sys, time, unicodedata, glob, shutil

BASE = os.environ.get('SERVER_EXPORT_DIR',
                      os.path.join(os.path.dirname(os.path.abspath(__file__)), 'staging', 'server-export'))
TDIR, SDIR = os.path.join(BASE, 'transcripts'), os.path.join(BASE, 'state')
AGENTS_DIR = os.environ.get('AGENTS_DIR', '/home/box/agent-data/agents')
PEND, POSF = os.path.join(SDIR, 'pending'), os.path.join(SDIR, 'positions.json')
HDR = re.compile(r'Transcript of (?:agent|conversation)?\s*"?(?P<name>.*?)"?\s*\((?P<id>[^)]+)\),\s*positions\s+'
                 r'(?P<a>\d+)\s*[–-]\s*(?P<b>\d+)\s+of\s+(?P<n>\d+)')
HDR2 = re.compile(r'positions\s+(?P<a>\d+)\s*[–-]\s*(?P<b>\d+)\s+of\s+(?P<n>\d+)')
OLDER = re.compile(r'before=(\d+)')

os.umask(0o077)


_TRANSLIT = str.maketrans({'ı': 'i', 'ß': 'ss', 'ø': 'o', 'ł': 'l', 'đ': 'd', 'æ': 'ae', 'œ': 'oe', 'þ': 'th'})


def slug(s):
    s = unicodedata.normalize('NFKD', s.translate(_TRANSLIT)).encode('ascii', 'ignore').decode()
    return re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-') or 'unnamed'


def load_pos():
    return json.load(open(POSF)) if os.path.exists(POSF) else {}


def save_pos(p):
    tmp = POSF + '.tmp'
    with open(tmp, 'w') as f: json.dump(p, f, indent=1, ensure_ascii=False, sort_keys=True)
    os.replace(tmp, POSF)


def canon(line):
    return json.dumps(json.loads(line), sort_keys=True, ensure_ascii=False)


def parse_chunk(path, fallback_id=None):
    """-> dict(id, name, a, b, n, lines[]) or dict(id, n=0) for an empty transcript, or None."""
    text = open(path, encoding='utf-8', errors='replace').read()
    lines, head = [], []
    for l in text.split('\n'):
        if l.startswith('{'):
            try: json.loads(l); lines.append(l); continue
            except ValueError: pass
        if not lines: head.append(l)   # header lives before the first message; never search message bodies
    head = '\n'.join(head)
    if fallback_id and not lines and 'No conversation, agent, or subagent' in head:
        return {'id': fallback_id, 'name': None, 'n': 0, 'empty': True, 'unreadable': True}
    m = HDR.search(head)
    if m:
        d = m.groupdict()
    else:
        m2 = HDR2.search(head)
        if not m2:
            if fallback_id and not lines:
                return {'id': fallback_id, 'name': None, 'n': 0, 'empty': True}
            return None
        d = dict(m2.groupdict(), id=fallback_id, name=None)
    if not d.get('id'):
        return None
    return {'id': d['id'].strip(), 'name': d.get('name'), 'a': int(d['a']), 'b': int(d['b']),
            'n': int(d['n']), 'lines': lines}


def profile_name(tid):
    """Display name from the on-box agent profile (AGENTS_DIR/<id>/profile.json), if any."""
    try:
        with open(os.path.join(AGENTS_DIR, tid, 'profile.json'), encoding='utf-8') as f:
            return json.load(f).get('name')
    except (OSError, ValueError):
        return None


def tfile(rec, tid):
    return os.path.join(TDIR, f"{tid}__{slug(rec.get('name') or tid)}.jsonl")


def stitch(pos, tid):
    rec = pos[tid]
    path = tfile(rec, tid)
    pdir = os.path.join(PEND, tid)
    pages = []
    for f in glob.glob(os.path.join(pdir, '*.jsonl')):
        a, b = map(int, os.path.basename(f)[:-6].split('-'))
        pages.append((a, b, f))
    pages.sort()
    changed = True
    while changed:
        changed = False
        M = rec.get('max_pos', -1)
        for a, b, f in list(pages):
            if b <= M:
                os.remove(f); pages.remove((a, b, f)); changed = True; continue
            if a > M + 1:
                continue
            new = [l for l in open(f, encoding='utf-8').read().split('\n') if l]
            if a <= M:  # overlap: drop the head lines already exported
                tail = []
                if os.path.exists(path):
                    with open(path, encoding='utf-8') as fh:
                        tail = [canon(l) for l in fh.read().split('\n')[-(len(new) + 5):] if l]
                cn = [canon(l) for l in new]
                k = 0
                for kk in range(min(len(tail), len(cn)), 0, -1):
                    if tail[-kk:] == cn[:kk]: k = kk; break
                if k == 0:
                    rec.setdefault('warnings', []).append(
                        f"{time.strftime('%F %T%z')}: overlap {a}-{M} matched no lines; appended page whole")
                new = new[k:]
            with open(path, 'a', encoding='utf-8') as fh:
                for l in new: fh.write(l + '\n')
            os.chmod(path, 0o600)
            rec['lines'] = rec.get('lines', 0) + len(new)
            rec['max_pos'] = b
            rec['last_export'] = time.strftime('%F %T%z')
            os.remove(f); pages.remove((a, b, f)); changed = True
            break
    if os.path.isdir(pdir) and not os.listdir(pdir): os.rmdir(pdir)
    rec['pending'] = [[a, b] for a, b, _ in pages]


def ingest(paths, remove=False, fallback_id=None):
    for d in (BASE, TDIR, SDIR, PEND): os.makedirs(d, mode=0o700, exist_ok=True); os.chmod(d, 0o700)
    pos = load_pos()
    touched = set()
    for p in paths:
        c = parse_chunk(p, fallback_id)
        if not c:
            print(f"SKIP (no transcript header): {p}", file=sys.stderr); continue
        tid = c['id']
        rec = pos.setdefault(tid, {'max_pos': -1, 'lines': 0})
        if c.get('name'): rec['name'] = c['name']
        if not rec.get('name'): rec['name'] = profile_name(tid)
        rec['unreadable'] = bool(c.get('unreadable'))
        rec['total'] = c['n']; rec['checked'] = time.strftime('%F %T%z')
        if c.get('empty'):
            rec.setdefault('last_export', rec['checked'])
        elif c['b'] > rec.get('max_pos', -1):
            pdir = os.path.join(PEND, tid); os.makedirs(pdir, mode=0o700, exist_ok=True)
            with open(os.path.join(pdir, f"{c['a']}-{c['b']}.jsonl"), 'w', encoding='utf-8') as fh:
                fh.write('\n'.join(c['lines']) + '\n')
        touched.add(tid)
        if remove: os.remove(p)
    for tid in touched: stitch(pos, tid)
    save_pos(pos); write_index(pos)
    print(json.dumps(next_calls(pos), ensure_ascii=False))


def next_calls(pos):
    """before value still needed per transcript (None = complete)."""
    out = {}
    for tid, r in pos.items():
        M = r.get('max_pos', -1)
        pend = r.get('pending') or []
        if pend:
            out[tid] = pend[0][0]          # page back from the oldest pending page
        elif r.get('total', 0) - 1 > M:
            out[tid] = 'newest'            # new messages since last export: fetch newest page
    return out


def write_index(pos):
    rows = sorted(pos.items(), key=lambda kv: (kv[1].get('name') or '').lower())
    with open(os.path.join(BASE, 'INDEX.md'), 'w', encoding='utf-8') as f:
        f.write(f"# Server-side transcript export — {time.strftime('%F %H:%M %z')}\n\n"
                "Pulled with ReadTranscript by the primary bot's daily routine and merged by server-export-merge.py.\n\n"
                "| bot / conversation | id | server messages | exported up to | lines | last export | status |\n|---|---|---|---|---|---|---|\n")
        for tid, r in rows:
            st = 'complete' if r.get('max_pos', -1) >= r.get('total', 0) - 1 and not r.get('pending') else \
                 f"gap (pending {r.get('pending')})"
            if r.get('total', 0) == 0: st = 'not readable via ReadTranscript' if r.get('unreadable') else 'empty'
            if r.get('warnings'): st += f", {len(r['warnings'])} warning(s)"
            f.write(f"| {r.get('name') or '?'} | `{tid}` | {r.get('total', 0)} | {r.get('max_pos', -1)} | "
                    f"{r.get('lines', 0)} | {r.get('last_export', '-')} | {st} |\n")
    os.chmod(os.path.join(BASE, 'INDEX.md'), 0o600)


def memory(paths, remove=False):
    mdir = os.path.join(BASE, 'memory'); os.makedirs(mdir, mode=0o700, exist_ok=True)
    out = os.path.join(mdir, 'primary-bot-and-shared.md')
    facts = set()
    if os.path.exists(out):
        facts = {l.rstrip('\n') for l in open(out, encoding='utf-8') if l.startswith('- (')}
    before, totals = len(facts), []
    for p in paths:
        text = open(p, encoding='utf-8', errors='replace').read()
        m = re.search(r'Top \d+ matches for "(.*?)".*?\((\d+)', text)
        if m: totals.append((m.group(1), int(m.group(2))))
        cur = None
        for l in text.split('\n'):
            if l.startswith('- ('):
                if cur: facts.add(cur)
                cur = l.rstrip()
            elif cur and l.startswith('  ') and l.strip():   # wrapped continuation line
                cur += ' ' + l.strip()
            else:
                if cur: facts.add(cur)
                cur = None
        if cur: facts.add(cur)
        if remove: os.remove(p)
    with open(out, 'w', encoding='utf-8') as f:
        f.write(f"# Memory export (RecallMemory: primary bot + owner's shared memory) — updated {time.strftime('%F %H:%M %z')}\n\n"
                "Collected with many RecallMemory queries (each returns at most ~15 facts), deduplicated, never pruned.\n"
                "Other bots' private memory is NOT reachable from the primary bot; their on-box memory files are in staging/brain.\n\n")
        for l in sorted(facts): f.write(l + '\n')
    os.chmod(out, 0o600)
    print(json.dumps({'facts': len(facts), 'new': len(facts) - before, 'query_totals': totals}, ensure_ascii=False))


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] not in ('ingest', 'next', 'index', 'memory'):
        print(__doc__); sys.exit(2)
    if a[0] == 'ingest':
        rm = '--remove' in a; a = [x for x in a[1:] if x != '--remove']
        fid = None
        if '--id' in a:
            i = a.index('--id'); fid = a[i + 1]; del a[i:i + 2]
        ingest(a, rm, fid)
    elif a[0] == 'memory':
        memory([x for x in a[1:] if x != '--remove'], '--remove' in a)
    elif a[0] == 'next':
        print(json.dumps(next_calls(load_pos()), ensure_ascii=False, indent=1))
    else:
        write_index(load_pos())
