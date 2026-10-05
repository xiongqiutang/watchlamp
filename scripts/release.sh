#!/bin/bash
# Builds a signed, notarized dist/Watchlamp-<version>.dmg that people can download and open.
#
# Needs, once per Mac:
#   1. A "Developer ID Application" certificate in the login keychain (security find-identity -v -p codesigning).
#   2. notarytool credentials saved in the keychain:
#        xcrun notarytool store-credentials watchlamp-notary --apple-id <Apple ID> --team-id <TEAM ID>
#      Another saved profile works too: NOTARY_PROFILE=<name> scripts/release.sh
# SIGN_ID picks the certificate (name or SHA-1); by default it is the Developer ID valid the longest.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-watchlamp-notary}"

longest_valid_identity() {  # SHA-1 of the Developer ID Application certificate that expires last
  python3 - <<'PY'
import datetime, re, subprocess
run = lambda *a: subprocess.run(a, capture_output=True, text=True).stdout
ids = re.findall(r'\) ([0-9A-F]{40}) "Developer ID Application:', run("security", "find-identity", "-v", "-p", "codesigning"))
ends = {}
for sha, pem in re.findall(r"SHA-1 hash: ([0-9A-F]+)\n(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)",
                           run("security", "find-certificate", "-a", "-c", "Developer ID Application", "-Z", "-p"), re.S):
    end = subprocess.run(["openssl", "x509", "-noout", "-enddate"], input=pem, capture_output=True, text=True).stdout
    ends[sha] = datetime.datetime.strptime(end.strip().split("=", 1)[1], "%b %d %H:%M:%S %Y %Z")
print(max((h for h in ids if h in ends), key=ends.get, default=""))
PY
}
SIGN_ID="${SIGN_ID:-$(longest_valid_identity)}"
[ -n "$SIGN_ID" ] || { echo "✗ No Developer ID Application certificate in the keychain." >&2; exit 1; }

./build.sh
APP="build/Watchlamp.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "• Signing with $(security find-identity -v -p codesigning | grep "$SIGN_ID" | sed 's/.*"\(.*\)"/\1/' | head -1) [${SIGN_ID:0:8}]"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"

# The hardened runtime must not break connecting (it edits settings.json through JavaScriptCore).
TRY=$(mktemp -d)
printf '{\n  "theme": "auto"\n}\n' > "$TRY/settings.json"
WATCHLAMP_CLAUDE_DIR="$TRY" WATCHLAMP_DIR="$TRY/state" "$APP/Contents/MacOS/Watchlamp" connect >/dev/null
[ "$(jq '.hooks | length' "$TRY/settings.json")" = 16 ] || { echo "✗ The signed app could not connect." >&2; exit 1; }
rm -rf "$TRY"

notarize() {  # notarize <file>: submit, wait, and stop with Apple's log if it is not accepted
  local out status id
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json) || true
  status=$(jq -r '.status // empty' <<< "$out" 2>/dev/null || true)
  id=$(jq -r '.id // empty' <<< "$out" 2>/dev/null || true)
  echo "  ${status:-Failed} ${id:+($id)}"
  if [ "$status" != "Accepted" ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

echo "• Notarizing the app"
ditto -c -k --keepParent "$APP" build/Watchlamp-notarize.zip
notarize build/Watchlamp-notarize.zip
xcrun stapler staple -q "$APP"

echo "• Building the disk image"
rm -rf build/dmg && mkdir -p build/dmg dist
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
DMG="dist/Watchlamp-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname Watchlamp -srcfolder build/dmg -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "• Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

echo "• Gatekeeper"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
spctl -a -vv "$APP" 2>&1 | sed 's/^/  /'
echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
