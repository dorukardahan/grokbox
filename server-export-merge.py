#!/usr/bin/env python3
"""Merge ReadTranscript (write_to_file) chunk files into staging/server-export/.

ReadTranscript is a Grok Bot tool, not callable from cron, so a bot's daily routine (GrokBox-Main, and
GrokBox-Assist for Main's own conversation) pulls the pages (in=<id>, limit=200, write_to_file=true, paging back with `before`) and runs:

  server-export-merge.py ingest [--remove] CHUNK...   merge chunks (idempotent; re-ingest is a no-op).
                                                     A chunk that cannot be trusted (invalid JSON message
                                                     line, unreadable, or no transcript header) is NOT
                                                     ingested (file kept, exit 3), so no message is lost
  server-export-merge.py next                         what to call next (JSON): per transcript the
                                                     `before` value still needed, or "newest"; {} = all complete
  server-export-merge.py index                        rewrite INDEX.md
  server-export-merge.py age [--max-hours 26] [ID...] hours since each id was last checked (JSON);
                                                     exit 1 if one is missing or older (did the routine run?)
  server-export-merge.py repair                       merge an id's history split over several files
                                                     (left by a bot rename in older versions); keeps originals
  server-export-merge.py memory [--remove] [--out NAME] [--label WHO] CHUNK...
                                                     merge RecallMemory (write_to_file) results into
                                                     memory/<NAME>.md (default primary-bot-and-shared; deduped, kept forever)

Layout (dir 700, files 600):
  transcripts/<id>__<slug>.jsonl   oldest first, one message per line
  state/positions.json             {id: {name, total, max_pos, lines, last_export, ...}}
  state/pending/<id>/<A>-<B>.jsonl pages not yet contiguous with what is exported (a gap remains)
Pages are stitched by the header range "positions A–B of N". A page that overlaps what is already
exported (the incremental case: newest page) is de-duplicated by matching the longest suffix of the
exported file against the page's head (positions and lines are not 1:1: tool results can share a slot).

Exit codes (check these, do not parse the stdout JSON to decide success; in a bot's shell surface
them, because `|| rc=$?` alone leaves the shell's own status 0: `... || rc=$?; echo "ingest_rc=$rc"`):
  ingest  0 = every result file was ingested (or was a no-op);
          3 = at least one page was REJECTED: invalid JSON lines, unreadable file, or no transcript
              header. The file is kept and its range is NOT recorded as exported (a rejected gap
              reappears in `next`'s output; a rejected newest page does not — the exit code is the
              only signal). Refetch that id with a smaller limit (a smaller page often survives what
              truncated the first one) and re-ingest; report it if the retry is rejected too.
  age     1 = an id was never checked or its last check is older than --max-hours.
  all     2 = bad usage (unknown subcommand/flags). Anything else is an unexpected error.
The JSON on stdout of `ingest`/`next` is always valid for the pages that WERE ingested; `{}` means
"nothing missing" only when the exit code was 0.
"""
import datetime, json, os, re, sys, time, unicodedata, glob, shutil

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


def write_atomic(path, text):
    """Write text to path via a temp file + fsync + rename: a crash never leaves a partial file."""
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp, 0o600); os.replace(tmp, path)


def save_pos(p):
    write_atomic(POSF, json.dumps(p, indent=1, ensure_ascii=False, sort_keys=True))


def canon(line):
    return json.dumps(json.loads(line), sort_keys=True, ensure_ascii=False)


class BadChunk(Exception):
    """A result file that must not be ingested (it would lose messages)."""


def parse_chunk(path, fallback_id=None):
    """-> dict(id, name, a, b, n, lines[]) or dict(id, n=0) for an empty transcript, or None."""
    text = open(path, encoding='utf-8', errors='replace').read()
    lines, head, bad = [], [], 0
    for l in text.split('\n'):
        if l.startswith('{'):
            try: json.loads(l); lines.append(l); continue
            except ValueError: bad += 1   # truncated/corrupt message line: never drop it silently
        if not lines: head.append(l)   # header lives before the first message; never search message bodies
    if bad:
        raise BadChunk(f"{bad} message line(s) are not valid JSON (truncated result?)")
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
    """Path of a transcript file. The slug follows the bot's current name; when a bot is renamed, the
    existing file is renamed too (one file per id), so history is never split across two files."""
    want = os.path.join(TDIR, f"{tid}__{slug(rec.get('name') or tid)}.jsonl")
    have = sorted(glob.glob(os.path.join(TDIR, f"{tid}__*.jsonl")), key=os.path.getmtime)
    if len(have) > 1:
        repair_split(tid, have)
        have = sorted(glob.glob(os.path.join(TDIR, f"{tid}__*.jsonl")), key=os.path.getmtime)
        if have:
            rec['bytes'] = os.path.getsize(have[0])   # merged size: keep the length record in sync
    if have and have[0] != want:
        os.replace(have[0], want)
    return want


def _overlap(old, new):
    """Largest k with old[-k:] == new[:k], compared as canonical JSON."""
    co, cn = [canon(l) for l in old[-(len(new) + 5):]], [canon(l) for l in new]
    for k in range(min(len(co), len(cn)), 0, -1):
        if co[-k:] == cn[:k]: return k
    return 0


def repair_split(tid, files):
    """Merge several files of one id (left by a rename in older versions) oldest first, dropping the
    overlap between consecutive files. The originals are kept in state/replaced/<time>/."""
    merged = []
    for f in files:
        new = [l for l in open(f, encoding='utf-8').read().split('\n') if l]
        merged += new[_overlap(merged, new):] if merged else new
    keep = os.path.join(SDIR, 'replaced', time.strftime('%Y%m%d-%H%M%S'))
    os.makedirs(keep, mode=0o700, exist_ok=True)
    for f in files: shutil.copy2(f, keep)
    tmp = files[-1] + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        for l in merged: fh.write(l + '\n')
    os.chmod(tmp, 0o600); os.replace(tmp, files[-1])
    for f in files[:-1]: os.remove(f)
    print(f"repaired {tid}: {len(files)} files -> 1 ({len(merged)} lines); originals in {keep}", file=sys.stderr)
    return len(merged)


def repair(pos):
    """Fix ids whose history is split over several files; correct their line counts."""
    for tid, rec in pos.items():
        have = sorted(glob.glob(os.path.join(TDIR, f"{tid}__*.jsonl")), key=os.path.getmtime)
        if len(have) > 1:
            n = repair_split(tid, have)
            rec['lines'] = n
            rec['bytes'] = os.path.getsize(tfile(rec, tid))   # merged size: keep the record in sync
            rec['warnings'] = [w for w in rec.get('warnings', []) if 'matched no lines' not in w]
            rec.setdefault('notes', []).append(
                f"{time.strftime('%F %T%z')}: repaired split history ({len(have)} files merged, overlap removed)")


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
                        tail = [l for l in fh.read().split('\n')[-(len(new) + 5):] if l]
                k = _overlap(tail, new)
                if k == 0:
                    rec.setdefault('warnings', []).append(
                        f"{time.strftime('%F %T%z')}: overlap {a}-{M} matched no lines; appended page whole")
                new = new[k:]
                rewrite = True
            elif rec.get('bytes') is not None and os.path.exists(path) and os.path.getsize(path) == rec['bytes']:
                # exact continuation of what is exported: append in place (single write + fsync)
                # instead of rewriting the whole file, so paging back through a long backlog is linear
                buf = ''.join(l + '\n' for l in new).encode('utf-8')
                with open(path, 'ab') as fh:
                    fh.write(buf); fh.flush(); os.fsync(fh.fileno())
                os.chmod(path, 0o600)
                rewrite = False
            else:
                # first page, or the file does not match the recorded length rec['bytes'] (the size
                # after the last completed write): a kill/ENOSPC during the in-place append can leave
                # a half-written line, so cut back to the recorded length and rewrite via temp file +
                # fsync + rename (max_pos/bytes are only advanced after the rename)
                if os.path.exists(path) and rec.get('bytes') is not None:
                    os.truncate(path, rec['bytes'])
                rewrite = True
            if rewrite:
                tmp = path + '.tmp'
                with open(tmp, 'w', encoding='utf-8') as fh:
                    if os.path.exists(path):
                        with open(path, encoding='utf-8') as old: shutil.copyfileobj(old, fh)
                    for l in new: fh.write(l + '\n')
                    fh.flush(); os.fsync(fh.fileno())
                os.chmod(tmp, 0o600); os.replace(tmp, path)
            rec['bytes'] = os.path.getsize(path)
            rec['lines'] = rec.get('lines', 0) + len(new)
            rec['max_pos'] = b
            rec['last_export'] = time.strftime('%F %T%z')
            os.remove(f); pages.remove((a, b, f)); changed = True
            break
    if os.path.isdir(pdir) and not os.listdir(pdir): os.rmdir(pdir)
    rec['pending'] = [[a, b] for a, b, _ in pages]


def ingest(paths, remove=False, fallback_id=None):
    """-> 0 when every file was ingested; 3 when at least one page was rejected (kept for a retry)."""
    for d in (BASE, TDIR, SDIR, PEND): os.makedirs(d, mode=0o700, exist_ok=True); os.chmod(d, 0o700)
    pos = load_pos()
    touched, failed = set(), []
    for p in paths:
        try:
            c = parse_chunk(p, fallback_id)
        except BadChunk as e:   # keep the file, do not record its range: the next run fetches it again
            failed.append(p); print(f"ERROR (not ingested, file kept): {p}: {e}", file=sys.stderr); continue
        except OSError as e:
            failed.append(p); print(f"ERROR (cannot read, not ingested): {p}: {e}", file=sys.stderr); continue
        if not c:   # no transcript header and no --id: cannot be attributed to any transcript
            failed.append(p); print(f"ERROR (not ingested, file kept): {p}: no transcript header (empty result?)", file=sys.stderr); continue
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
            write_atomic(os.path.join(pdir, f"{c['a']}-{c['b']}.jsonl"), '\n'.join(c['lines']) + '\n')
        touched.add(tid)
        if remove: os.remove(p)
    for tid in touched: stitch(pos, tid)
    save_pos(pos); write_index(pos)
    print(json.dumps(next_calls(pos), ensure_ascii=False))
    if failed:
        print(f"ERROR: {len(failed)} result file(s) were NOT ingested (invalid JSON lines, unreadable or "
              f"no transcript header); refetch those pages, a smaller limit often helps", file=sys.stderr)
        return 3
    return 0


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


def age(pos, ids, max_h):
    """Hours since each id was last checked; exit 1 if one is missing or older than max_h."""
    now, out, bad = time.time(), {}, False
    for tid in ids or sorted(pos):
        c = (pos.get(tid) or {}).get('checked')
        h = None if not c else round((now - datetime.datetime.strptime(c, '%Y-%m-%d %H:%M:%S%z').timestamp()) / 3600, 1)
        out[tid] = h
        bad |= h is None or h > max_h
    print(json.dumps(out, indent=1))
    return 1 if bad else 0


def write_index(pos):
    rows = sorted(pos.items(), key=lambda kv: (kv[1].get('name') or '').lower())
    with open(os.path.join(BASE, 'INDEX.md'), 'w', encoding='utf-8') as f:
        f.write(f"# Server-side transcript export — {time.strftime('%F %H:%M %z')}\n\n"
                "Pulled with ReadTranscript by the GrokBox-Main daily routine (GrokBox-Assist exports Main's own conversation)\n"
                "and merged by server-export-merge.py.\n\n"
                "| bot / conversation | id | server messages | exported up to | lines | last export | status |\n|---|---|---|---|---|---|---|\n")
        for tid, r in rows:
            st = 'complete' if r.get('max_pos', -1) >= r.get('total', 0) - 1 and not r.get('pending') else \
                 f"gap (pending {r.get('pending')})"
            if r.get('total', 0) == 0: st = 'not readable via ReadTranscript' if r.get('unreadable') else 'empty'
            if r.get('warnings'): st += f", {len(r['warnings'])} warning(s)"
            f.write(f"| {r.get('name') or '?'} | `{tid}` | {r.get('total', 0)} | {r.get('max_pos', -1)} | "
                    f"{r.get('lines', 0)} | {r.get('last_export', '-')} | {st} |\n")
    os.chmod(os.path.join(BASE, 'INDEX.md'), 0o600)


def memory(paths, remove=False, out_name='primary-bot-and-shared', label='primary bot'):
    mdir = os.path.join(BASE, 'memory'); os.makedirs(mdir, mode=0o700, exist_ok=True)
    out = os.path.join(mdir, slug(out_name) + '.md')
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
        f.write(f"# Memory export (RecallMemory: {label} + owner's shared memory) — updated {time.strftime('%F %H:%M %z')}\n\n"
                "Collected with many RecallMemory queries (each returns at most ~15 facts), deduplicated, never pruned.\n"
                "RecallMemory only returns the calling bot's own memory and the owner's shared memory; other bots'\n"
                "on-box memory files (agents/<id>/memory/) are in the brain export.\n\n")
        for l in sorted(facts): f.write(l + '\n')
    os.chmod(out, 0o600)
    print(json.dumps({'facts': len(facts), 'new': len(facts) - before, 'query_totals': totals}, ensure_ascii=False))


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] not in ('ingest', 'next', 'index', 'memory', 'repair', 'age'):
        print(__doc__); sys.exit(2)
    import fcntl   # two bots may run this at the same time: one writer at a time
    os.makedirs(SDIR, mode=0o700, exist_ok=True)
    _lock = open(os.path.join(SDIR, '.lock'), 'w'); fcntl.flock(_lock, fcntl.LOCK_EX)
    if a[0] == 'ingest':
        rm = '--remove' in a; a = [x for x in a[1:] if x != '--remove']
        fid = None
        if '--id' in a:
            i = a.index('--id'); fid = a[i + 1]; del a[i:i + 2]
        sys.exit(ingest(a, rm, fid))
    elif a[0] == 'memory':
        rm = '--remove' in a; a = [x for x in a[1:] if x != '--remove']
        kw = {}
        for opt, key in (('--out', 'out_name'), ('--label', 'label')):
            if opt in a:
                i = a.index(opt); kw[key] = a[i + 1]; del a[i:i + 2]
        memory(a, rm, **kw)
    elif a[0] == 'repair':
        pos = load_pos(); repair(pos); save_pos(pos); write_index(pos)
    elif a[0] == 'age':
        a = a[1:]; mh = 26.0
        if '--max-hours' in a:
            i = a.index('--max-hours'); mh = float(a[i + 1]); del a[i:i + 2]
        sys.exit(age(load_pos(), a, mh))
    elif a[0] == 'next':
        print(json.dumps(next_calls(load_pos()), ensure_ascii=False, indent=1))
    else:
        write_index(load_pos())
