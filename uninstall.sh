#!/bin/bash
# Remove the hooks, the login item, the app and its state.
set -uo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Applications/Watchlamp.app"
python3 scripts/hooks.py uninstall
[ -x "$DEST/Contents/MacOS/Watchlamp" ] && "$DEST/Contents/MacOS/Watchlamp" login off >/dev/null
pkill -x Watchlamp 2>/dev/null
rm -rf "$DEST" "$HOME/.claude/watchlamp/sessions"
defaults delete app.watchlamp 2>/dev/null
echo "Watchlamp 已卸载（设置备份保留在 ~/.claude/watchlamp/backups）。"
