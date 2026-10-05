#!/bin/bash
# Build, install to ~/Applications, hook into Claude Code, and start Watchlamp.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications/Watchlamp.app"
pkill -x Watchlamp 2>/dev/null && sleep 0.5 || true

# Carry over an install from before the rename (ClaudeStatusLight), keeping its settings and state.
OLD="$HOME/Applications/ClaudeStatusLight.app"
if [ -d "$OLD" ]; then
  "$OLD/Contents/MacOS/ClaudeStatusLight" login off >/dev/null 2>&1 || true
  pkill -x ClaudeStatusLight 2>/dev/null && sleep 0.5 || true
  rm -rf "$OLD"
fi
if defaults read local.claude-status-light >/dev/null 2>&1; then
  defaults export local.claude-status-light - | defaults import app.watchlamp -
  defaults delete local.claude-status-light
fi
if [ -d "$HOME/.claude/status-light" ]; then
  for dir in sessions backups; do
    [ -d "$HOME/.claude/status-light/$dir" ] && ditto "$HOME/.claude/status-light/$dir" "$HOME/.claude/watchlamp/$dir"
  done
  rm -rf "$HOME/.claude/status-light"
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Watchlamp.app "$DEST"
touch "$DEST"

python3 scripts/hooks.py install "$DEST/Contents/MacOS/Watchlamp"
open "$DEST"

echo
echo "Watchlamp 已安装并启动：$DEST"
echo "Claude Code 会话（桌面版和终端版）一有动作就会亮灯；个别没亮的会话重开一次即可。"
