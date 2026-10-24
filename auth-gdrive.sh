#!/usr/bin/env bash
# Google Drive authorisation for rclone. The token is written straight into a chmod-600 file under
# secrets/ and is never printed.
#   auth-gdrive.sh                       RECOMMENDED: your own OAuth client from
#                                        secrets/gdrive-oauth-client.json (Desktop app; see docs/google-cloud-setup.md)
#   auth-gdrive.sh --rclone-default-client   FALLBACK: rclone's built-in shared client (see warning below)
#   auth-gdrive.sh --reauth              redo authorisation even if a token exists
# Remote name and folder come from config.env (GB_REMOTE, GB_FOLDER; defaults gdrive, GrokBox/restic).
# Flow: rclone's OAuth helper listens on http://127.0.0.1:53682 on THIS box. The script prints the URL
# (also saved to the chmod-600 file state/auth-url.txt, only while the flow runs); open it in the box's
# browser, sign in, click Allow. It waits up to 10 minutes, so a bot should run it in the background
# and read its output. The URL file and the rclone output file are deleted when the script ends.
# Scope drive.file = rclone sees only files/folders created by the same OAuth client.
source "$(dirname "$0")/lib.sh"; set +e; trap - ERR
umask 077
RCLONE="$GB_BIN/rclone"
MODE=own; REAUTH=0
for a in "$@"; do case "$a" in
  --rclone-default-client) MODE=default;; --reauth) REAUTH=1;;
  -h|--help) sed -n 2,13p "$0"; exit 0;; *) echo "unknown arg $a"; exit 2;; esac; done
[[ -x "$RCLONE" ]] || { echo "rclone missing: run ./install.sh first"; exit 1; }
mkdir -p "$GB_SECRETS"; chmod 700 "$GB_SECRETS"
URL_FILE="$GB_STATE/auth-url.txt"
out="$GB_LOGS/auth-$GB_REMOTE.out"; CHILD=""
# Whatever happens (done, timeout, signal): stop the OAuth helper, never keep the URL or its output.
cleanup() { [[ -n "$CHILD" ]] && kill "$CHILD" 2>/dev/null; rm -f "$URL_FILE" "$out"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP

wait_for_consent() {  # waits for the OAuth helper ($CHILD, output in $out); 0 only if it exited 0
  local url rc
  for _ in $(seq 1 30); do grep -q 'http://127.0.0.1:53682/auth' "$out" && break; kill -0 "$CHILD" 2>/dev/null || break; sleep 1; done
  url=$(grep -o 'http://127.0.0.1:53682/auth?state=[A-Za-z0-9_-]*' "$out" | head -1)
  [[ -n "$url" ]] || { echo "rclone did not print an auth URL. Last lines:"; grep -vi token "$out" | tail -5; return 1; }
  echo "$url" > "$URL_FILE"; chmod 600 "$URL_FILE"
  echo "OPEN THIS URL in the box browser (the human signs in with their Google account and clicks Allow):"
  echo "$url"
  echo "(one-time localhost URL; also in $URL_FILE until this script ends)"
  echo "Waiting for consent (max 10 min)..."
  for _ in $(seq 1 600); do kill -0 "$CHILD" 2>/dev/null || break; sleep 1; done
  if kill -0 "$CHILD" 2>/dev/null; then echo "Timed out waiting for consent (10 min); stopping the OAuth helper."; return 1; fi
  wait "$CHILD"; rc=$?; CHILD=""
  (( rc == 0 )) || { echo "OAuth helper failed (exit $rc). Last lines:"; grep -vi token "$out" | tail -5; return 1; }
}
# 0 = token present and section is type=drive/scope=drive.file, 1 = no token, 2 = token but wrong type/scope
have_token() {
  [[ -s "$RCLONE_CONFIG" ]] || return 1
  python3 - "$RCLONE_CONFIG" "$GB_REMOTE" <<'PY'
import configparser,sys
c=configparser.ConfigParser(interpolation=None); c.read(sys.argv[1])
s=c[sys.argv[2]] if c.has_section(sys.argv[2]) else {}
if not s.get("token"): sys.exit(1)
sys.exit(0 if s.get("type")=="drive" and s.get("scope")=="drive.file" else 2)
PY
}
if [[ $REAUTH == 0 ]]; then
  have_token; t=$?
  if (( t == 0 )); then
    if "$RCLONE" --config "$RCLONE_CONFIG" about "$GB_REMOTE:" >/dev/null 2>&1; then
      echo "remote $GB_REMOTE already authorised and working (use --reauth to redo)."; exit 0; fi
    echo "remote $GB_REMOTE has a token but 'rclone about' fails (revoked, expired or Drive unreachable)."
  elif (( t == 2 )); then echo "remote $GB_REMOTE exists but is not type=drive with scope=drive.file."; fi
  if (( t != 1 )); then
    echo "If the problem persists: delete $RCLONE_CONFIG (or its [$GB_REMOTE] section) and run ./auth-gdrive.sh again (or use --reauth)."; exit 1; fi
fi
mkdir -p "$GB_LOGS"; : > "$out"; chmod 600 "$out"

if [[ $MODE == own ]]; then
  CLIENT_JSON="$GB_SECRETS/gdrive-oauth-client.json"
  if [[ ! -s "$CLIENT_JSON" ]]; then
    echo "missing $CLIENT_JSON"
    echo "Create a Desktop-app OAuth client (docs/google-cloud-setup.md), download its JSON and save it there."
    echo "Only if you cannot: ./auth-gdrive.sh --rclone-default-client (read the warning first)."; exit 1; fi
  # write the remote section from the client JSON without ever putting the secret on a command line
  if ! python3 - "$CLIENT_JSON" "$RCLONE_CONFIG" "$GB_REMOTE" <<'PY'
import json,sys,os,re
d=json.load(open(sys.argv[1])); c=d.get("installed") or d.get("web") or {}
assert c.get("client_id") and c.get("client_secret"), "client JSON lacks client_id/client_secret"
path,name=sys.argv[2],sys.argv[3]
old=open(path).read() if os.path.exists(path) else ""
# drop an existing [name] section, keep every other section
old=re.sub(r"(?ms)^\[%s\]\n.*?(?=^\[|\Z)" % re.escape(name), "", old)
new=old.rstrip("\n")+("\n\n" if old.strip() else "")+f"[{name}]\ntype = drive\nclient_id = {c['client_id']}\nclient_secret = {c['client_secret']}\nscope = drive.file\n"
tmp=path+".tmp"
fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_TRUNC, 0o600)
with os.fdopen(fd,"w") as f: f.write(new)
os.replace(tmp,path)
print(f"wrote remote [{name}] into {path} (client secret not shown)")
PY
  then exit 1; fi
  env -u DISPLAY "$RCLONE" --config "$RCLONE_CONFIG" config reconnect "$GB_REMOTE:" --auto-confirm >>"$out" 2>&1 &
  CHILD=$!
else
  cat <<'WARN'
################################################################################################
# WARNING: you chose rclone's built-in (shared) OAuth client.
#  - It is shared by every rclone user in the world; Google rate-limits it ("rateLimitExceeded")
#    and it may be retired at any time. Backups can then fail or become slow.
#  - Because the scope is drive.file, files are only visible to the client that created them. If you
#    later switch to your own client you must create a NEW folder and `restic copy` the history
#    (docs/migrate-client.md).
# The recommended path is your own client (docs/google-cloud-setup.md). Continuing anyway...
################################################################################################
WARN
  # DISPLAY unset so rclone does not pop a browser on some agent's desktop; we hand out the URL ourselves.
  env -u DISPLAY "$RCLONE" config create "$GB_REMOTE" drive scope=drive.file config_is_local=true \
      --config "$RCLONE_CONFIG" >>"$out" 2>&1 &
  CHILD=$!
fi
wait_for_consent "$out" || exit 1
chmod 600 "$RCLONE_CONFIG" 2>/dev/null
if "$RCLONE" --config "$RCLONE_CONFIG" about "$GB_REMOTE:" >/dev/null 2>&1; then
  "$RCLONE" --config "$RCLONE_CONFIG" mkdir "$GB_REMOTE:$GB_FOLDER" \
    && echo "OK: Drive connected as remote '$GB_REMOTE'; folder '$GB_FOLDER' ready. Next: ./install.sh --init"
else echo "Auth not completed. Last log lines:"; grep -vi token "$out" | tail -5; exit 1; fi
