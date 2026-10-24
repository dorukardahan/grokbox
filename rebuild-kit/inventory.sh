#!/usr/bin/env bash
# Snapshot of installed tooling so a fresh box can be rebuilt. Output lands in $GB_STATE/rebuild-kit/
# (inside the backup when state/ is under a backup root): inventory.txt + venvs/*.txt freezes.
# shellcheck source=/dev/null
source "$(dirname "$0")/../lib.sh"; set +e; trap - ERR
out="$GB_STATE/rebuild-kit"; mkdir -p "$out/venvs"
{
echo "# Box tool inventory $(date '+%F %H:%M %Z')"; echo "## OS"; grep PRETTY /etc/os-release; uname -m
echo "## Key CLIs (path / version)"
for t in git curl jq ffmpeg node npm pnpm yarn bun go gh uv python3 pip3 convert magick yt-dlp google-chrome chromium; do
  p=$(command -v "$t" 2>/dev/null) || { echo "MISSING $t"; continue; }
  v=$("$t" --version 2>/dev/null | head -1); printf '%s\t%s\t%s\n' "$t" "$p" "$v"; done
echo "## apt manually installed"; apt-mark showmanual 2>/dev/null | tr '\n' ' '; echo
echo "## /usr/local/bin"; find /usr/local/bin -maxdepth 1 -mindepth 1 -printf "%f\n" 2>/dev/null | tr '\n' ' '; echo
echo "## ~/.local/bin"; find "$HOME/.local/bin" -maxdepth 1 -mindepth 1 -printf "%f\n" 2>/dev/null | tr '\n' ' '; echo
echo "## npm -g"; npm ls -g --depth=0 2>/dev/null | tail -n +2
echo "## uv tools"; uv tool list 2>/dev/null
} > "$out/inventory.txt"
pip3 list --user --format=freeze 2>/dev/null > "$out/venvs/_pip-user.txt"
for r in "${BACKUP_ROOTS[@]}"; do
  find "$r" -xdev -name pyvenv.cfg -not -path '*/node_modules/*' 2>/dev/null
done | while read -r c; do
  d=$(dirname "$c"); n=$(echo "${d#/}" | tr '/' '_'); py="$d/bin/python"
  { echo "# venv: $d"; grep -E '^(version|home)' "$c"
    if [[ -x "$py" ]]; then "$py" -m pip freeze 2>/dev/null || { command -v uv >/dev/null && uv pip freeze --python "$py" 2>/dev/null; }; fi
  } > "$out/venvs/$n.txt"
done
echo ok
