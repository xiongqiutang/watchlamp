#!/bin/bash
# Developer build with the commands that are not shipped in the app:
#   scripts/devtools.sh snapshot out.png [h|v] [size] [palette] [lang]   render the board to a PNG (SNAPSHOT_CLEAR=1: transparent)
#   scripts/devtools.sh demo [seconds]                              put three sample lamps on the live board
#   scripts/devtools.sh status                                      list the recorded sessions
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="build/dev/watchlamp-dev"
if [ ! -x "$DEV" ] || [ -n "$(find Sources -name '*.swift' -newer "$DEV" | head -1)" ]; then
  mkdir -p build/dev
  swiftc -Onone -swift-version 5 -D DEVTOOLS -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit -framework ServiceManagement -framework UserNotifications -o "$DEV" Sources/*.swift
fi
exec "$DEV" "$@"
