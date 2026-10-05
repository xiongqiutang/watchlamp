#!/bin/bash
# Builds build/Watchlamp.app (needs Xcode or the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Watchlamp.app"
BIN="$APP/Contents/MacOS/Watchlamp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
for f in "$APP"/Contents/Resources/*.lproj/*.strings; do plutil -convert binary1 "$f"; done

swiftc -Osize -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework ServiceManagement -Xlinker -dead_strip \
  -o "$BIN" Sources/*.swift
strip -x "$BIN"

# App icon, drawn by a build-time script. Up to 256 px is plenty for a menu bar app.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
[ build/render-icon -nt scripts/RenderIcon.swift ] || swiftc -O -o build/render-icon scripts/RenderIcon.swift
build/render-icon build/icon-1024.png
for size in 16 32 128 256; do
  sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128; do
  sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
