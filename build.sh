#!/bin/bash
# Builds DockPlus.app next to this script.
#   ./build.sh                       ad-hoc signed (fine for personal use)
#   SIGN_ID="Apple Development: You (TEAMID)" ./build.sh
#                                    signed with a stable identity, so macOS keeps the
#                                    Accessibility / Screen Recording grants across rebuilds
#
# The app is always signed with Hardened Runtime (--options runtime). DockPlus holds
# Accessibility and Screen Recording; without Hardened Runtime, any program running as you
# could relaunch it with injected code (DYLD_INSERT_LIBRARIES) and borrow those rights.
# Don't add entitlements that relax it (disable-library-validation,
# allow-dyld-environment-variables, and similar).
set -euo pipefail
cd "$(dirname "$0")"

APP="DockPlus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc -O -swift-version 5 DockPlus.swift -o "$APP/Contents/MacOS/DockPlus"

# local.dockplus is fine for personal use. To share the app, use a reverse-DNS ID you own,
# sign with a Developer ID certificate, and notarize it.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>local.dockplus</string>
    <key>CFBundleName</key>                <string>DockPlus</string>
    <key>CFBundleExecutable</key>          <string>DockPlus</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

codesign --force --options runtime --sign "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP"
# Captured first rather than piped into `grep -q`, which can SIGPIPE codesign under pipefail.
SIGNATURE_INFO="$(codesign --display --verbose "$APP" 2>&1)"
if ! grep -q 'flags=.*runtime' <<<"$SIGNATURE_INFO"; then
    echo "error: $APP is not signed with Hardened Runtime" >&2
    exit 1
fi

echo "Built $(pwd)/$APP (Hardened Runtime on)"
echo "Next: move it to /Applications and open it from Finder. Don't run the binary inside it"
echo "from Terminal, or macOS will ask to give Terminal these permissions instead. Allow"
echo "Accessibility, and Screen Recording when the first window preview asks for it."
