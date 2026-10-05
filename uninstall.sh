#!/bin/bash
# Remove the hooks, the login item, the app and its state (for installs made with install.sh).
# A downloaded copy can do the same from its menu: "Disconnect from Claude Code", then drag it to the Trash.
set -uo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Applications/Watchlamp.app"
BIN="$DEST/Contents/MacOS/Watchlamp"
[ -x "$BIN" ] || BIN="build/Watchlamp.app/Contents/MacOS/Watchlamp"
if [ -x "$BIN" ]; then
  "$BIN" disconnect
  "$BIN" login off >/dev/null
else
  echo "找不到 Watchlamp 程序，没能移除 ~/.claude/settings.json 里的钩子（它们只是不再起作用）。"
fi
pkill -x Watchlamp 2>/dev/null
rm -rf "$DEST" "$HOME/.claude/watchlamp/sessions"
defaults delete app.watchlamp 2>/dev/null
echo "Watchlamp 已卸载（设置备份保留在 ~/.claude/watchlamp/backups）。"
