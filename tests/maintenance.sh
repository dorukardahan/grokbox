#!/usr/bin/env bash
# Maintenance tests: PRUNE_USE_TRASH serve args + docs, server-export-merge.py exit codes / atomic
# pending writes / crash-safe appends, restore.sh (--help, exit codes, private temp, backup.lock),
# LOG_RETENTION_DAYS cleanup, the nightly quota/disk check (including its once-a-day gate in
# check.sh) and the doctor.sh quota rows. Offline: local restic repo in a temp dir, a fake rclone
# for the Drive quota, no network, no real secrets.
#   tests/maintenance.sh              run (restic is reused from <repo>/bin)
#   KEEP_TMP=1 tests/maintenance.sh   keep the temp directory for inspection
# shellcheck disable=SC2016  # bash -c snippets expand later; fixture text stays literal
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/grokbox-maint.XXXXXX")"
export RESTIC_CACHE_DIR="$TMP/cache"
[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] || { echo "refusing: temp dir $TMP is not under /tmp"; exit 1; }
cleanup() { [[ -n "${KEEP_TMP:-}" ]] && { echo "kept $TMP"; return; }
  chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RCLONE_CONFIG
BIN="$REPO_DIR/bin"
[[ -x "$BIN/restic" ]] || { echo "bin/restic missing (run tests/smoke.sh once to download it)"; exit 1; }

PASS_N=0; FAIL_N=0
pass() { PASS_N=$((PASS_N+1)); echo "  ok   - $*"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "  FAIL - $*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
run_ok() { local d="$1"; shift; if "$@" >"$TMP/last.out" 2>&1; then pass "$d"; else fail "$d"; sed 's/^/       | /' "$TMP/last.out" | tail -15; fi; }
not() { ! "$@"; }
step() { echo; echo "== $*"; }
# rc_of CMD... -> the command's exit code (output discarded)
rc_of() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

# --- shared fixture: a small source tree + a local restic repo, driven through a temp config
SRC="$TMP/src"; REPO="$TMP/restic-repo"; RTMPDIR="$TMP/rtmp"
mkdir -p "$SRC/docs" "$RTMPDIR" "$TMP/secrets" "$TMP/restore"
PASSF="$TMP/restic-pass"; printf 'maint-pw-%s-%s' "$$" "$RANDOM" > "$PASSF"; chmod 600 "$PASSF"
cat > "$TMP/config.env" <<CFG
GB_BIN="$BIN"
GB_SECRETS="$TMP/secrets"
GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"; GB_STAGING="$TMP/staging"; GB_CACHE="$TMP/cache"
source "$REPO_DIR/config.env.example"
export AGENTS_DIR="$TMP/agents"
export DELETED_BOTS_FILE="$TMP/no-deleted-agents.json"
export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSF"
BACKUP_ROOTS=("$SRC")
BACKUP_HOST=testhost
RESTORE_BASE="$TMP/restore"
CFG
export GB_CONFIG="$TMP/config.env"
rs() { "$BIN/restic" -r "$REPO" --password-file "$PASSF" "$@"; }
for i in 0 1 2 3 4 5 6 7 8 9; do printf 'maint-%s\n' "$i" > "$SRC/docs/file$i.txt"; done
rs init >/dev/null 2>&1
rs backup --host testhost --tag auto "$SRC" >/dev/null 2>&1

# --- fake binaries: rclone only answers `about` (quota checks); restic fails a restore after
# writing partial output (alert path). Neither ever touches the network or a real repository.
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/rclone" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" about "*)
  [[ -n "${FAKE_ABOUT_COUNT:-}" ]] && echo x >> "$FAKE_ABOUT_COUNT"
  [[ "${FAKE_ABOUT_RC:-0}" != 0 ]] && exit "$FAKE_ABOUT_RC"
  [[ -n "${FAKE_ABOUT_JSON:-}" ]] && printf '%s\n' "$FAKE_ABOUT_JSON";; esac
exit 0
EOF
cat > "$FB/restic" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  snapshots) printf '[{"hostname":"testhost","id":"deadbeefdeadbeef"}]' ;;
  restore) t=""; prev=""
           for a in "$@"; do [[ "$prev" == "--target" ]] && t="$a"; prev="$a"; done
           mkdir -p -- "$t"; echo partial > "$t/partial.txt"; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FB/rclone" "$FB/restic"

step "PRUNE_USE_TRASH -> rclone serve args (RT) for forget/prune"
cp "$TMP/config.env" "$TMP/rc.env"; echo 'export RESTIC_REPOSITORY="rclone:fake:GrokBox/restic"' >> "$TMP/rc.env"
ta=$(GB_CONFIG="$TMP/rc.env" bash -c 'source "$1/lib.sh"; printf "%s|%s" "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "default (1): forget/prune use --drive-use-trash=true, normal calls keep false" bash -c '[[ "${1%%|*}" == *use-trash=false* && "${1#*|}" == *use-trash=true* && "${1#*|}" != *use-trash=false* ]]' _ "$ta"
cp "$TMP/rc.env" "$TMP/rc0.env"; echo 'PRUNE_USE_TRASH=0' >> "$TMP/rc0.env"
ta0=$(GB_CONFIG="$TMP/rc0.env" bash -c 'source "$1/lib.sh"; printf "%s|%s" "${RESTIC_OPTS[*]}" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "PRUNE_USE_TRASH=0: forget/prune pass --drive-use-trash=false explicitly, never true" bash -c '[[ "${1#*|}" == *use-trash=false* && "${1#*|}" != *use-trash=true* ]]' _ "$ta0"
check "PRUNE_USE_TRASH=0: normal calls unchanged (still false)" bash -c '[[ "${1%%|*}" == "${2%%|*}" ]]' _ "$ta0" "$ta"
cat > "$TMP/old.env" <<CFG
GB_BIN="$BIN"; GB_SECRETS="$TMP/secrets"; GB_STATE="$TMP/state"; GB_LOGS="$TMP/logs"
GB_STAGING="$TMP/staging"; RESTIC_CACHE_DIR="$TMP/cache"; BACKUP_ROOTS=("$SRC")
RCLONE_SERVE_ARGS="--drive-use-trash=false --tpslimit 8"
export RESTIC_REPOSITORY="rclone:fake:GrokBox/restic"
CFG
tao=$(GB_CONFIG="$TMP/old.env" bash -c 'source "$1/lib.sh"; printf "%s" "${RESTIC_OPTS_TRASH[*]}"' _ "$REPO_DIR")
check "older config.env without PRUNE_USE_TRASH: lib.sh default is trash ON (true)" bash -c '[[ "$1" == *use-trash=true* && "$1" != *use-trash=false* ]]' _ "$tao"
check "README documents the trash opt-out" grep -q 'PRUNE_USE_TRASH=0' "$REPO_DIR/README.md"
check "config.env.example documents the trash opt-out" grep -q 'PRUNE_USE_TRASH=0' "$REPO_DIR/config.env.example"
check "AGENTS.md documents the trash opt-out" grep -q 'PRUNE_USE_TRASH=0' "$REPO_DIR/AGENTS.md"

step "server-export-merge.py ingest exit codes + atomic/append writes"
SE="$TMP/server-export"; FX="$TMP/se-fx"; mkdir -p "$FX" "$TMP/se-agents/bot-t1"
echo '{"name":"Test Bot"}' > "$TMP/se-agents/bot-t1/profile.json"
# page ID A B N MSG... -> a ReadTranscript result file (header, JSON lines, footer)
page() { local id=$1 a=$2 b=$3 n=$4; shift 4; {
  printf 'Transcript of agent "Test Bot" (%s), positions %s\xe2\x80\x93%s of %s:\n\n' "$id" "$a" "$b" "$n"
  for m in "$@"; do printf '{"role":"user","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$m"; done
  [[ $a -gt 0 ]] && printf '\nOlder messages remain: call ReadTranscript again with the same in and before=%s.\n' "$a"; true; }; }
sem() { DELETED_BOTS_FILE="$TMP/deleted-agents.json" SERVER_EXPORT_DIR="$SE" AGENTS_DIR="$TMP/se-agents" python3 "$REPO_DIR/server-export-merge.py" "$@"; }
texts() { python3 -c 'import sys,json,glob
print(" ".join(json.loads(l)["message"]["content"][0]["text"]
              for f in sorted(glob.glob(sys.argv[1]+"/transcripts/"+sys.argv[2]+"__*.jsonl")) for l in open(f) if l.strip()))' "$SE" "$1"; }
tfile() { ls "$SE"/transcripts/"$1"__*.jsonl; }
page bot-t1 0 2 9 m0 m1 m2 > "$FX/a0.txt"
check "first page ingests (exit 0)" test "$(rc_of sem ingest "$FX/a0.txt")" = 0
check "positions.json records the exported byte length" grep -q '"bytes"' "$SE/state/positions.json"
ino=$(stat -c %i "$(tfile bot-t1)")
page bot-t1 3 5 9 m3 m4 m5 > "$FX/a1.txt"; sem ingest "$FX/a1.txt" >/dev/null
check "exact-continuation page appended in place (same inode, no full rewrite)" test "$(stat -c %i "$(tfile bot-t1)")" = "$ino"
# a kill/ENOSPC during that append can leave a half-written line; the next ingest must cut the file
# back to the recorded length and apply the page exactly once (no fragment, no duplicate)
printf '%s' '{"role":"user","message":{"content":[{"type":"text","text":"m6"}' >> "$(tfile bot-t1)"
page bot-t1 6 8 9 m6 m7 m8 > "$FX/a2.txt"
check "a half-written line left by a killed append is healed (exit 0)" test "$(rc_of sem ingest "$FX/a2.txt")" = 0
check "...fragment removed, the page applied exactly once" test "$(texts bot-t1)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8"
check "...every line in the file is valid JSON" python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$(tfile bot-t1)"
check "no .tmp files left" test -z "$(find "$SE" -name '*.tmp')"
check "complete -> next prints {}" test "$(sem next | tr -d ' \n')" = '{}'
sum=$(sha256sum "$(tfile bot-t1)" | cut -d ' ' -f1)
check "re-ingesting the same pages is a no-op (exit 0)" test "$(rc_of sem ingest "$FX/a0.txt" "$FX/a1.txt" "$FX/a2.txt")" = 0
check "...and leaves the transcript byte-identical" test "$(sha256sum "$(tfile bot-t1)" | cut -d ' ' -f1)" = "$sum"
# rejected pages: exit 3, file kept, nothing recorded, the range stays "missing" and heals on retry
sum=$(sha256sum "$(tfile bot-t1)" | cut -d ' ' -f1)
{ printf 'Transcript of agent "Test Bot" (bot-t1), positions 9\xe2\x80\x9311 of 12:\n\n'
  printf '{"role":"user","message":{"content":[{"type":"text","text":"m9"}]}}\n{"role":"user","messa\n'; } > "$FX/bad.txt"
check "truncated JSON line -> ingest exits 3" test "$(rc_of sem ingest "$FX/bad.txt")" = 3
check "...the result file is kept for a retry" test -f "$FX/bad.txt"
check "...the transcript is unchanged" test "$(sha256sum "$(tfile bot-t1)" | cut -d ' ' -f1)" = "$sum"
# a rejected NEWEST page never updates `total`, so next keeps printing {} - the exit code is the
# ONLY signal here (that is why the routines must check it, not the JSON output)
check "...next still prints {} for a rejected newest page (only exit 3 signals it)" test "$(sem next | tr -d ' \n')" = '{}'
page bot-t1 9 11 12 m9 m10 m11 > "$FX/a3.txt"
check "refetching the rejected range succeeds (exit 0)" test "$(rc_of sem ingest "$FX/a3.txt")" = 0
check "...transcript complete after the retry" test "$(texts bot-t1)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11"
printf 'a result file without any transcript header\n' > "$FX/nh.txt"
check "no transcript header -> ingest exits 3, file kept" test "$(rc_of sem ingest "$FX/nh.txt")" = 3 -a -f "$FX/nh.txt"
check "unreadable chunk file -> ingest exits 3" test "$(rc_of sem ingest "$FX/does-not-exist.txt")" = 3
page bot-t1 9 13 14 m9 m10 m11 m12 m13 > "$FX/ov.txt"
check "overlapping newest page de-duplicated on ingest (exit 0)" test "$(rc_of sem ingest --remove "$FX/ov.txt")" = 0
check "...overlap removed, new lines kept" test "$(texts bot-t1)" = "m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13"
# gap pages land in state/pending (atomically) until the missing older page arrives
page bot-t2 6 8 10 p6 p7 p8 > "$FX/g1.txt"; sem ingest "$FX/g1.txt" >/dev/null
check "gap page stored as pending" test -f "$SE/state/pending/bot-t2/6-8.jsonl"
check "pending page written atomically (600, no .tmp)" test "$(stat -c %a "$SE/state/pending/bot-t2/6-8.jsonl")" = 600 -a -z "$(find "$SE/state/pending" -name '*.tmp')"
check "next reports the gap as a before value" test "$(sem next | tr -d ' \n')" = '{"bot-t2":6}'
page bot-t2 0 5 10 p0 p1 p2 p3 p4 p5 > "$FX/g0.txt"; sem ingest "$FX/g0.txt" >/dev/null
check "filling the gap completes the transcript" test "$(texts bot-t2)" = "p0 p1 p2 p3 p4 p5 p6 p7 p8"
printf 'No conversation, agent, or subagent you can read from here has the id "bot-t3".\n' > "$FX/u.txt"
check "unreadable id (--id) recorded with exit 0" test "$(rc_of sem ingest --id bot-t3 "$FX/u.txt")" = 0
check "INDEX.md shows it as not readable" grep -q 'not readable' "$SE/INDEX.md"
check "age: a just-checked id passes (exit 0)" test "$(rc_of sem age bot-t1)" = 0
check "age: a never-exported id fails (exit 1)" test "$(rc_of sem age bot-t1 bot-missing)" = 1
check "no subcommand -> usage, exit 2" test "$(rc_of sem)" = 2
check "unknown subcommand -> usage, exit 2" test "$(rc_of sem bogus)" = 2

# An overlapping retry must also discard a partial append before reading the transcript tail.
mkdir -p "$TMP/se-agents/bot-t4"
echo '{"name":"Test Bot"}' > "$TMP/se-agents/bot-t4/profile.json"
page bot-t4 0 2 3 m0 m1 m2 > "$FX/partial0.txt"
check "overlap recovery: first page ingests (exit 0)" test "$(rc_of sem ingest "$FX/partial0.txt")" = 0
printf '%s' '{"role":"user","message":{"content":[{"type":"text","text":"m3"}' >> "$(tfile bot-t4)"
page bot-t4 1 4 5 m1 m2 m3 m4 > "$FX/partial-overlap.txt"
check "overlapping page heals a half-written append (exit 0)" test "$(rc_of sem ingest "$FX/partial-overlap.txt")" = 0
check "...overlap fragment removed, no duplicates" test "$(texts bot-t4)" = "m0 m1 m2 m3 m4"
check "...every overlap recovery line is valid JSON" python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1])]' "$(tfile bot-t4)"
check "...overlap recovery leaves no .tmp files" test -z "$(find "$SE" -name '*.tmp')"

# Independent deleted fixtures: exercise the CLI without any real agent data.
run_ok "deleted merger: flags, labels, statuses, parsing, next, revival and unchanged transcript bytes" python3 - "$REPO_DIR/server-export-merge.py" "$TMP" <<'PYDELETED'
import json, os, subprocess, sys
from pathlib import Path
script, tmp = sys.argv[1], Path(sys.argv[2])
base = tmp / 'deleted-export'
state = base / 'state'
state.mkdir(parents=True)
deleted = tmp / 'merger-deleted.json'
env = dict(os.environ, SERVER_EXPORT_DIR=str(base), AGENTS_DIR=str(tmp / 'se-agents'),
           DELETED_BOTS_FILE=str(deleted))
def run(*args):
    return subprocess.check_output([sys.executable, script, *args], env=env, text=True)
def positions():
    return json.loads((state / 'positions.json').read_text())
def index():
    # Ignore the generated timestamp when comparing content across minute boundaries.
    return (base / 'INDEX.md').read_text().split('\n', 1)[-1]
def row(tid):
    return next(l for l in index().splitlines() if f'`{tid}`' in l)
chunk = tmp / 'deleted-chunk.txt'
chunk.write_text('Transcript of agent "Helper Bot" (bot-a), positions 0-1 of 2:\n'
                 '{"text":"first"}\n{"text":"second"}\n')
run('ingest', str(chunk))
p = positions()
p.update({'bot-active': dict(name='Helper Bot', total=5, max_pos=0),
          'bot-gap': dict(name='Old Bot', total=5, max_pos=1, pending=[[4, 4]]),
          'bot-none': dict(total=5, max_pos=-1),
          'bot-empty': dict(name='Empty', total=0),
          'bot-unreadable': dict(name='Hidden', total=5, max_pos=1, unreadable=True),
          'bot-zero-kept': dict(total=0, max_pos=3, unreadable=True),
          'bot-zero-readable': dict(total=0, max_pos=2),
          'bot-capped': dict(total=2, max_pos=9, unreadable=True),
          'bot-no-data': {},
          'bot-hidden-empty': dict(total=0, unreadable=True),
          'bot-suffix': dict(name='Old Bot (deleted)', total=0)})
(state / 'positions.json').write_text(json.dumps(p, sort_keys=True))
run('index')
active_index = index()
files = {f.name: f.read_bytes() for f in (base / 'transcripts').iterdir()}
ids = [i for i in p if i != 'bot-active']
# All accepted list shapes, including metadata and invalid list members.
for payload in ({'agents': {i: {} for i in ids}}, {'agents': ids},
                {'agents': [{'id': i} for i in ids]}, ids,
                [{'id': i} for i in ids] + [None, 3, {'id': []}],
                dict({i: {} for i in ids}, version=1)):
    deleted.write_text(json.dumps(payload))
    run('index')
    assert all(positions()[i]['deleted'] is True for i in ids)
    assert positions()['bot-a']['name'] == 'Helper Bot'
    assert '| Helper Bot (deleted) |' in row('bot-a')
    assert '| Helper Bot |' in row('bot-active')
    assert 'deleted, history kept (complete)' in row('bot-a')
    assert 'deleted, history kept (2 of 5 messages, export incomplete)' in row('bot-gap')
    assert 'deleted, nothing exported (0 of 5 messages)' in row('bot-none')
    for i, kept in [('bot-unreadable', 2), ('bot-zero-kept', 4),
                    ('bot-zero-readable', 3), ('bot-capped', 2)]:
        assert f'deleted, history kept ({kept} messages, no longer readable)' in row(i)
    for i in ['bot-empty', 'bot-suffix', 'bot-no-data', 'bot-hidden-empty']:
        assert 'deleted before first export' in row(i)
    assert '| ? (deleted) |' in row('bot-none')
    assert '(deleted) (deleted)' not in index()
    before_pos, before_index = (state / 'positions.json').read_bytes(), index()
    run('index')
    assert (state / 'positions.json').read_bytes() == before_pos
    assert index() == before_index
    assert {f.name: f.read_bytes() for f in (base / 'transcripts').iterdir()} == files
    assert json.loads(run('next')) == {'bot-active': 'newest'}
# Repair refreshes and persists flags even when no split files need repair.
before_index = index()
p = positions()
for r in p.values(): r.pop('deleted', None)
(state / 'positions.json').write_text(json.dumps(p))
run('repair')
assert all(positions()[i]['deleted'] is True for i in ids)
assert index() == before_index
assert {f.name: f.read_bytes() for f in (base / 'transcripts').iterdir()} == files
deleted.write_text('[]')
run('repair')
assert all('deleted' not in r for r in positions().values())
assert index() == active_index
deleted.write_text(json.dumps(ids))
# Ingest refreshes all flags, including untouched ids, without renaming transcripts.
p = positions()
for r in p.values(): r.pop('deleted', None)
(state / 'positions.json').write_text(json.dumps(p))
run('ingest', str(chunk))
assert all(positions()[i]['deleted'] is True for i in ids)
assert positions()['bot-a']['name'] == 'Helper Bot'
assert '| Helper Bot (deleted) |' in row('bot-a')
assert {f.name: f.read_bytes() for f in (base / 'transcripts').iterdir()} == files
# next consults the current list even before index refreshes stored flags.
deleted.write_text('[]')
assert 'bot-gap' in json.loads(run('next'))
run('index')
assert all('deleted' not in r for r in positions().values())
assert index() == active_index
for kind in ['missing', 'garbled', 'empty', 'directory', 'disabled']:
    path = tmp / ('deleted-' + kind)
    if kind == 'garbled': path.write_bytes(b'\xffinvalid JSON')
    if kind == 'empty': path.touch()
    if kind == 'directory': path.mkdir()
    env['DELETED_BOTS_FILE'] = '' if kind == 'disabled' else str(path)
    # A stale true flag must also be cleared on invalid input.
    p = positions(); p['bot-a']['deleted'] = True
    (state / 'positions.json').write_text(json.dumps(p))
    run('index')
    assert all('deleted' not in r for r in positions().values())
    assert index() == active_index
# Revival through ingest also clears flags.
p = positions(); p['bot-a']['deleted'] = True
(state / 'positions.json').write_text(json.dumps(p))
run('ingest', str(chunk))
assert 'deleted' not in positions()['bot-a']
assert {f.name: f.read_bytes() for f in (base / 'transcripts').iterdir()} == files
PYDELETED

step "restore.sh --help, exit codes, private temp, backup.lock"
rc=0; GB_CONFIG=/nonexistent/config "$REPO_DIR/restore.sh" --help >"$TMP/h.out" 2>&1 || rc=$?
check "--help works with no config at all (before lib.sh/need_creds), exit 0" test "$rc" = 0
check "--help documents exit codes" grep -q 'Exit codes' "$TMP/h.out"
check "--help output has no code lines" not grep -q 'lib.sh' "$TMP/h.out"
rc=0; "$REPO_DIR/restore.sh" >"$TMP/h.out" 2>&1 || rc=$?
check "no arguments -> usage, exit 0" test "$rc" = 0
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" --host >"$TMP/h.out" 2>&1 || rc=$?
check "--host without a name -> exit 2" test "$rc" = 2
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" --bogus >"$TMP/h.out" 2>&1 || rc=$?
check "unknown option -> exit 2" test "$rc" = 2
mkdir -p "$TMP/notarepo"
{ cat "$TMP/config.env"; echo "export RESTIC_REPOSITORY=\"$TMP/notarepo\""; } > "$TMP/config-bad.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-bad.env" "$REPO_DIR/restore.sh" --bogus >"$TMP/h.out" 2>&1 || rc=$?
check "unknown option is rejected BEFORE any repository access (unreachable repo still -> exit 2, not 7)" test "$rc" = 2
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" --missing-only >"$TMP/h.out" 2>&1 || rc=$?
check "a flag where the snapshot id belongs -> exit 2" test "$rc" = 2
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" --any-host >"$TMP/h.out" 2>&1 || rc=$?
check "--any-host without a command -> usage, exit 0" test "$rc" = 0
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" list >"$TMP/r.out" 2>&1 || rc=$?
check "list works (exit 0, shows the host)" test "$rc" = 0 -a "$(grep -c testhost "$TMP/r.out")" -gt 0
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" ls latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "ls works (exit 0)" test "$rc" = 0 -a "$(grep -c file0.txt "$TMP/r.out")" -gt 0
check "no shared restore-hosts.json.tmp left in state" not test -e "$TMP/state/restore-hosts.json.tmp"
check "private temp dir cleaned up (trap)" test -z "$(ls -A "$RTMPDIR")"
{ cat "$TMP/config.env"; echo 'BACKUP_HOST=other-host'; } > "$TMP/config-host.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" list >"$TMP/r.out" 2>&1 || rc=$?
check "list with a host that has 0 snapshots -> exit 4" test "$rc" = 4
check "...and lists the hosts that do have snapshots" grep -q 'Hosts in this repository.*testhost' "$TMP/r.out"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-bad.env" "$REPO_DIR/restore.sh" list >"$TMP/r.out" 2>&1 || rc=$?
check "unreachable repo -> exit 7" test "$rc" = 7
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-host.env" "$REPO_DIR/restore.sh" --any-host list >"$TMP/r.out" 2>&1 || rc=$?
check "--any-host list skips the host check (exit 0)" test "$rc" = 0
# a restore dir that already exists gets its own exit code (5), before any restic work
# (the dir names are pre-created in UTC: lib.sh forces TZ=$TZ, which is UTC in this config)
for s in 0 1 2 3 4 5 6 7 8; do mkdir -p "$TMP/restore/restore-$(TZ=UTC date -d "@$(( $(date +%s) + s ))" +%Y%m%d-%H%M%S)-futurex"; done
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" futurex >"$TMP/r.out" 2>&1 || rc=$?
check "existing restore dir -> its own exit code 5 (distinct from restic failures)" test "$rc" = 5
check "...with a clear message" grep -q 'exists:' "$TMP/r.out"
( exec 9>>"$TMP/state/backup.lock"; flock 9; exec sleep 120 ) & LPID=$!
# wait until the holder provably holds the lock before asserting on restore.sh's
# behaviour (a blind sleep here raced under load and blamed restore.sh for it)
held=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n 9 9>>"$TMP/state/backup.lock" 2>/dev/null || { held=yes; break; }
  sleep 1
done
check "test harness: the holder really holds backup.lock" test "$held" = yes
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" ls latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "read-only ls works while a backup holds backup.lock" test "$rc" = 0
{ cat "$TMP/config.env"; echo 'RESTORE_LOCK_WAIT=2'; } > "$TMP/config-w.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/config-w.env" "$REPO_DIR/restore.sh" latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "restore while the lock is held -> exit 8 after RESTORE_LOCK_WAIT" test "$rc" = 8
check "...with a clear message naming backup.lock" grep -q 'backup.lock' "$TMP/r.out"
check "no restore dir was created" test -z "$(find "$TMP/restore" -maxdepth 1 -name 'restore-*' ! -name 'restore-*futurex' 2>/dev/null)"
kill "$LPID" 2>/dev/null || true; wait "$LPID" 2>/dev/null || true
sleep 1
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" latest "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "restore with a free lock -> exit 0" test "$rc" = 0
RD="$(find "$TMP/restore" -maxdepth 1 -name 'restore-*' ! -name '*futurex' | head -1)"
check "files really restored into the restore dir" test -f "$RD$SRC/docs/file0.txt"
check "lock-holder records the restore run" grep -q ' restore$' "$TMP/state/lock-holder"
rm -f "$TMP/state/ALERT"
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" nosuchsnap >"$TMP/r.out" 2>&1 || rc=$?
check "restic restore failure -> exit 9 (own code, distinct from usage/exists)" test "$rc" = 9
check "...message names the raw restic rc" grep -qE 'restic restore failed rc=[0-9]+' "$TMP/r.out"
check "...no output dir was created" test -z "$(find "$TMP/restore" -maxdepth 1 -name '*nosuchsnap*' 2>/dev/null)"
check "a mistyped snapshot id raises NO persistent alert" not test -e "$TMP/state/ALERT"
{ cat "$TMP/config.env"; echo "GB_BIN=\"$FB\""; } > "$TMP/fr.env"
rc=0; TMPDIR="$RTMPDIR" GB_CONFIG="$TMP/fr.env" "$REPO_DIR/restore.sh" latest >"$TMP/r.out" 2>&1 || rc=$?
check "a restore failing AFTER writing partial output -> exit 9 + persistent alert" bash -c '[[ "$1" == 9 ]] && grep -q "restic restore of latest failed" "$2"' _ "$rc" "$TMP/state/ALERT"
check "...and the message mentions the partial output" grep -q 'partial output may be in' "$TMP/r.out"
rm -f "$TMP/state/ALERT"
rm "$SRC/docs/file5.txt"; printf 'changed-live\n' > "$SRC/docs/file0.txt"; sleep 1
rc=0; TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" latest --missing-only --yes "$SRC/docs" >"$TMP/r.out" 2>&1 || rc=$?
check "--missing-only: exit 0" test "$rc" = 0
check "--missing-only: missing file came back" test -f "$SRC/docs/file5.txt"
check "--missing-only: existing (modified) file NOT overwritten" test "$(cat "$SRC/docs/file0.txt")" = changed-live
check "private temp dir still clean" test -z "$(ls -A "$RTMPDIR")"
# the interactive --missing-only prompt must wait WITHOUT holding backup.lock (it may wait for a
# human for hours; the hourly backups must keep running meanwhile)
rm -f "$SRC/docs/file7.txt"
( sleep 8; echo n ) | TMPDIR="$RTMPDIR" "$REPO_DIR/restore.sh" latest --missing-only "$SRC/docs" >"$TMP/m.out" 2>&1 &
MPID=$!
busy=no
for _ in $(seq 1 100); do
  flock -n 9 9>>"$TMP/state/backup.lock" 2>/dev/null || { busy=yes; break; }
  sleep 0.1
done
check "test harness: the restore really took backup.lock first" test "$busy" = yes
freed=no
for _ in $(seq 1 100); do
  flock -n 9 9>>"$TMP/state/backup.lock" 2>/dev/null && { freed=yes; break; }
  sleep 0.1
done
check "the --missing-only prompt waits WITHOUT holding backup.lock" test "$freed" = yes
check "...and the process is still waiting at the prompt" kill -0 "$MPID"
mrc=0; wait "$MPID" || mrc=$?
check "declined copy-back -> exit 0, file left missing" test "$mrc" = 0 -a ! -e "$SRC/docs/file7.txt"
check "private temp dir clean after the prompt too" test -z "$(ls -A "$RTMPDIR")"

step "log retention (LOG_RETENTION_DAYS, default keep forever)"
L="$TMP/logs"; mkdir -p "$L" "$TMP/elsewhere"
echo old > "$L/backup-2000-01.log"; touch -d '400 days ago' "$L/backup-2000-01.log"
echo old > "$L/backup-2001-01.log"; touch -d '40 days ago' "$L/backup-2001-01.log"
echo keep > "$TMP/elsewhere/backup-1999-01.log"; touch -d '400 days ago' "$TMP/elsewhere/backup-1999-01.log"
echo a > "$L/alerts.log"; touch -d '400 days ago' "$L/alerts.log"
echo b > "$L/alerts-acked.log"; touch -d '400 days ago' "$L/alerts-acked.log"
run_ok "default LOG_RETENTION_DAYS: log-retention.sh is a no-op" env GB_CONFIG="$TMP/config.env" "$REPO_DIR/log-retention.sh"
check "default keeps everything" test -f "$L/backup-2000-01.log" -a -f "$L/backup-2001-01.log"
{ cat "$TMP/config.env"; echo 'LOG_RETENTION_DAYS=30'; } > "$TMP/lr.env"
run_ok "log-retention.sh with LOG_RETENTION_DAYS=30" env GB_CONFIG="$TMP/lr.env" "$REPO_DIR/log-retention.sh"
check "logs older than 30d deleted" not test -e "$L/backup-2000-01.log" -o -e "$L/backup-2001-01.log"
check "current month log kept" test -f "$L/backup-$(date +%Y-%m).log"
check "alerts.log never deleted (however old)" test -f "$L/alerts.log"
check "alerts-acked.log never deleted" test -f "$L/alerts-acked.log"
check "nothing outside GB_LOGS is touched" test -f "$TMP/elsewhere/backup-1999-01.log"
check "cleanup is logged" grep -q 'log retention: deleted 2 log file' "$L/backup-$(date +%Y-%m).log"
touch -d '400 days ago' "$L/backup-$(date +%Y-%m).log"
run_ok "after a long pause the current month's log has an old mtime too" env GB_CONFIG="$TMP/lr.env" "$REPO_DIR/log-retention.sh"
check "the log currently being written is excluded by name and kept" test -f "$L/backup-$(date +%Y-%m).log"
echo old > "$L/backup-2002-01.log"; touch -d '400 days ago' "$L/backup-2002-01.log"
{ cat "$TMP/config.env"; echo 'LOG_RETENTION_DAYS=not-a-number'; } > "$TMP/lrx.env"
run_ok "an invalid LOG_RETENTION_DAYS is not fatal" env GB_CONFIG="$TMP/lrx.env" "$REPO_DIR/log-retention.sh"
check "invalid setting keeps everything" test -f "$L/backup-2002-01.log"
echo old > "$L/backup-2003-01.log"; touch -d '40 days ago' "$L/backup-2003-01.log"
{ cat "$TMP/config.env"; echo 'LOG_RETENTION_DAYS=08'; } > "$TMP/lr0.env"
run_ok "LOG_RETENTION_DAYS=08 works (decimal 8, never octal)" env GB_CONFIG="$TMP/lr0.env" "$REPO_DIR/log-retention.sh"
check "...the 40-day-old log was deleted" not test -e "$L/backup-2003-01.log"

step "quota + local disk monitoring (quota-check.sh)"
mkq() { # mkq NAME SETTING -> temp config using the fake rclone + an rclone: repo
  { cat "$TMP/config.env"; echo "GB_BIN=\"$FB\""; echo 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"'; printf '%s\n' "$2"; } > "$TMP/$1"; }
# the same alert text is deduped for ALERT_DEDUPE_HOURS: acknowledge before asserting a new one
noalerts() { GB_CONFIG="$TMP/config.env" "$REPO_DIR/status.sh" --ack >/dev/null 2>&1 || true; rm -f "$TMP/state/ALERT"; }
mkq q1.env 'QUOTA_ALERT_PCT=90'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":102005473280,"trashed":0}' GB_CONFIG="$TMP/q1.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "quota-check exits 0" test "$rc" = 0
check "quota.status: drive_pct=95" grep -q '^drive_pct=95$' "$TMP/state/quota.status"
check "quota.status: drive_used bytes recorded" grep -q '^drive_used=102005473280$' "$TMP/state/quota.status"
check "quota.status: drive_total bytes recorded" grep -q '^drive_total=107374182400$' "$TMP/state/quota.status"
check "quota.status: local disk + time present" bash -c 'grep -q "^disk_pct=[0-9]" "$1" && grep -qE "^time=[0-9]+$" "$1"' _ "$TMP/state/quota.status"
check "alert at >= QUOTA_ALERT_PCT (95 >= 90)" grep -q 'Google Drive 95% full' "$TMP/state/ALERT"
rm -f "$TMP/state/ALERT"
mkq q2.env 'QUOTA_ALERT_PCT=98'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":10737418240}' GB_CONFIG="$TMP/q2.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "10% used: exit 0, no alert" test "$rc" = 0 -a ! -e "$TMP/state/ALERT"
check "quota.status updated (drive_pct=10)" grep -q '^drive_pct=10$' "$TMP/state/quota.status"
mkq q3.env 'QUOTA_ALERT_PCT=90'
rc=0; FAKE_ABOUT_RC=1 GB_CONFIG="$TMP/q3.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "rclone about failing: not fatal (exit 0)" test "$rc" = 0
check "...quota.status keeps disk values, drive values absent" bash -c 'grep -q "^disk_pct=" "$1" && ! grep -q "^drive_" "$1"' _ "$TMP/state/quota.status"
check "...and the failure is one log line" grep -q 'rclone about fakedrive: failed' "$L/backup-$(date +%Y-%m).log"
rc=0; FAKE_ABOUT_JSON='this is not json' GB_CONFIG="$TMP/q3.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "unparsable about output: not fatal, drive values absent" bash -c '[[ "$1" == 0 ]] && ! grep -q "^drive_" "$2"' _ "$rc" "$TMP/state/quota.status"
rc=0; FAKE_ABOUT_JSON='[1,2]' GB_CONFIG="$TMP/q3.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "about JSON that is not an object: not fatal, no traceback" bash -c '[[ "$1" == 0 ]] && ! grep -q "Traceback" "$2"' _ "$rc" "$TMP/q.out"
# Drive's `used` counts only Drive files: Gmail/Photos sit in `other`. The percentage must follow
# the account-wide quota, or a quota filled by mail/photos would never reach the alert threshold.
noalerts
mkq q5.env 'QUOTA_ALERT_PCT=90'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":10737418240,"other":91268055040,"free":5368709120}' GB_CONFIG="$TMP/q5.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "drive_pct uses the account quota (total-free): 95, not the Drive-files-only 10" grep -q '^drive_pct=95$' "$TMP/state/quota.status"
check "...drive_other and drive_free recorded" bash -c 'grep -q "^drive_other=91268055040$" "$1" && grep -q "^drive_free=5368709120$" "$1"' _ "$TMP/state/quota.status"
check "...alert fires although Drive files are only 10%" grep -q 'Google Drive 95% full' "$TMP/state/ALERT"
rm -f "$TMP/state/ALERT"
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":10737418240,"other":91268055040}' GB_CONFIG="$TMP/q5.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "without free: drive_pct falls back to used+other (95)" grep -q '^drive_pct=95$' "$TMP/state/quota.status"
noalerts
mkq q6.env 'QUOTA_ALERT_PCT=90'
rc=0; FAKE_ABOUT_JSON='{"total":1000000,"used":895000}' GB_CONFIG="$TMP/q6.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "89.5% floors to 89 (never rounds UP into the 90% alert)" bash -c '[[ "$1" == 0 ]] && grep -q "^drive_pct=89$" "$2" && { [[ ! -e "$3" ]] || ! grep -q "Google Drive" "$3"; }' _ "$rc" "$TMP/state/quota.status" "$TMP/state/ALERT"
mkq q7.env 'QUOTA_ALERT_PCT=90%'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":10737418240}' GB_CONFIG="$TMP/q7.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "invalid QUOTA_ALERT_PCT falls back to 90: logged, not fatal, no alert" bash -c '[[ "$1" == 0 ]] && { [[ ! -e "$2" ]] || ! grep -q "Google Drive" "$2"; }' _ "$rc" "$TMP/state/ALERT"
check "...fallback is logged" grep -q "QUOTA_ALERT_PCT='90%' is not a number; using 90" "$L/backup-$(date +%Y-%m).log"
noalerts
mkq q8.env 'QUOTA_ALERT_PCT=090'
rc=0; FAKE_ABOUT_JSON='{"total":107374182400,"used":102005473280}' GB_CONFIG="$TMP/q8.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "QUOTA_ALERT_PCT=090 is decimal 90 (no octal surprise): the 95% alert fires" bash -c '[[ "$1" == 0 ]] && grep -q "Google Drive 95% full" "$2"' _ "$rc" "$TMP/state/ALERT"
rm -f "$TMP/state/ALERT"
{ cat "$TMP/config.env"; echo 'QUOTA_ALERT_PCT=1'; } > "$TMP/q4.env"
rc=0; GB_CONFIG="$TMP/q4.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "local disk alert fires at >= QUOTA_ALERT_PCT" bash -c '[[ "$1" == 0 ]] && grep -q "local disk" "$2"' _ "$rc" "$TMP/state/ALERT"
check "non-rclone repo: no drive_* keys written" not grep -q '^drive_' "$TMP/state/quota.status"
rm -f "$TMP/state/ALERT"
mkdir -p "$TMP/dfbin"
cat > "$TMP/dfbin/df" <<'EOF'
#!/usr/bin/env bash
# fake df: one filesystem whose mount point contains a space
echo 'Filesystem 1024-blocks Used Available Capacity Mounted-on'
echo '/dev/x 100 50 50 42% /srv/my data'
EOF
chmod +x "$TMP/dfbin/df"
rc=0; PATH="$TMP/dfbin:$PATH" GB_CONFIG="$TMP/config.env" "$REPO_DIR/quota-check.sh" >"$TMP/q.out" 2>&1 || rc=$?
check "a mount point containing a space is kept whole in disk_path" bash -c '[[ "$1" == 0 ]] && grep -q "^disk_path=/srv/my data$" "$2"' _ "$rc" "$TMP/state/quota.status"
check "check.sh runs both nightly jobs" bash -c 'grep -q "log-retention.sh" "$1" && grep -q "quota-check.sh" "$1"' _ "$REPO_DIR/check.sh"

step "check.sh: nightly housekeeping runs at most once a day (no Drive query per lock retry)"
echo '[fakedrive]' > "$TMP/secrets/rclone.conf"
{ cat "$TMP/config.env"; echo "GB_BIN=\"$FB\""; echo 'export RESTIC_REPOSITORY="rclone:fakedrive:GrokBox/restic"';
  echo "export RCLONE_CONFIG=\"$TMP/secrets/rclone.conf\""; } > "$TMP/chk.env"
( exec 9>>"$TMP/state/backup.lock"; flock 9; exec sleep 300 ) & HPID=$!
held=no
for _ in $(seq 1 100); do
  flock -n 9 9>>"$TMP/state/backup.lock" 2>/dev/null || { held=yes; break; }
  sleep 0.1
done
check "test harness: backup.lock is held" test "$held" = yes
chk() { local r=0; FAKE_ABOUT_COUNT="$TMP/about.count" FAKE_ABOUT_JSON='{"total":107374182400,"used":10737418240}' \
  LOCK_WAIT=2 GB_CONFIG="$TMP/chk.env" "$REPO_DIR/check.sh" >"$TMP/chk.out" 2>&1 || r=$?; echo "$r"; }
rm -f "$TMP/state/housekeeping-day" "$TMP/about.count"
check "check.sh with a busy lock exits 75 (the scheduler retries every minute)" test "$(chk)" = 75
check "...housekeeping ran once before the lock attempt (one rclone about)" test "$(wc -l < "$TMP/about.count")" = 1
check "...and wrote the day stamp" test -s "$TMP/state/housekeeping-day"
check "the immediate retry does NOT query Drive again (stamp gate)" test "$(chk)" = 75 -a "$(wc -l < "$TMP/about.count")" = 1
rm -f "$TMP/state/housekeeping-day"
check "a new day runs housekeeping again" test "$(chk)" = 75 -a "$(wc -l < "$TMP/about.count")" = 2
kill "$HPID" 2>/dev/null || true; wait "$HPID" 2>/dev/null || true

step "doctor.sh: quota rows follow QUOTA_ALERT_PCT and flag missing/stale samples"
DOC="$TMP/docstate"; mkdir -p "$DOC"
{ cat "$TMP/config.env"; echo "GB_STATE=\"$DOC\""; } > "$TMP/doc.env"
doc() { GB_CONFIG="$TMP/doc.env" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true; }
doc
check "no quota.status yet -> WARN, not a silent OK" grep -q '^WARN *quota/disk: unknown: no usable state/quota.status' "$TMP/doc.out"
printf 'drive_pct=95\ndisk_pct=30\ntime=%s\n' "$(date +%s)" > "$DOC/quota.status"; doc
check "at/over QUOTA_ALERT_PCT (95 >= 90) -> PROBLEM" grep -q '^PROBLEM *quota/disk' "$TMP/doc.out"
printf 'drive_pct=50\ndisk_pct=30\ntime=%s\n' "$(date +%s)" > "$DOC/quota.status"; doc
check "below the threshold -> OK" grep -q '^OK *quota/disk' "$TMP/doc.out"
printf 'drive_pct=50\ndisk_pct=30\ntime=%s\n' "$(( $(date +%s) - 49*3600 ))" > "$DOC/quota.status"; doc
check "quota.status older than 48 h -> WARN (stale sample)" grep -q '^WARN *quota/disk: measured .*stale' "$TMP/doc.out"
{ cat "$TMP/doc.env"; echo 'QUOTA_ALERT_PCT=50'; } > "$TMP/doc50.env"
printf 'drive_pct=60\ndisk_pct=30\ntime=%s\n' "$(date +%s)" > "$DOC/quota.status"
GB_CONFIG="$TMP/doc50.env" "$REPO_DIR/doctor.sh" >"$TMP/doc.out" 2>&1 || true
check "the PROBLEM threshold follows QUOTA_ALERT_PCT (60 >= 50 -> PROBLEM, not the fixed 90)" grep -q '^PROBLEM *quota/disk' "$TMP/doc.out"

echo; echo "maintenance tests: $PASS_N passed, $FAIL_N failed"
[[ $FAIL_N == 0 ]]
