#!/bin/bash
# Builds DockPlus.app next to this script.
#   ./build.sh                       ad-hoc signed (fine for personal use)
#   SIGN_ID="Apple Development: You (TEAMID)" ./build.sh
#                                    signed with a stable identity, so macOS keeps the
#                                    Accessibility / Screen Recording grants across rebuilds
#   SIGN_ID="Developer ID Application: You (TEAMID)" NOTARY_PROFILE=dockplus ./build.sh
#                                    signed for distribution, notarized and stapled, so
#                                    Gatekeeper opens it on other Macs without warnings.
#                                    NOTARY_PROFILE names credentials saved once with
#                                    `xcrun notarytool store-credentials`.
#   VERSION=1.1 BUILD_NUMBER=2       set the version shown in Finder (default 1.0 / 1)
#
# DockPlus is built for Apple silicon only (arm64), also when building on an Intel Mac.
#
# Use ./make-dmg.sh to wrap the result in a drag-to-Applications disk image.
#
# The app is always signed with Hardened Runtime (--options runtime). DockPlus holds
# Accessibility and Screen Recording; without Hardened Runtime, any program running as you
# could relaunch it with injected code (DYLD_INSERT_LIBRARIES) and borrow those rights.
# Don't add entitlements that relax it (disable-library-validation,
# allow-dyld-environment-variables, and similar).
set -euo pipefail
cd "$(dirname "$0")"

APP="DockPlus.app"
# macOS ties the Accessibility and Screen Recording grants to this ID, so don't change it
# once the app has users.
BUNDLE_ID="com.chrism4rtinez.dockplus"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_ID" != "Developer ID Application"* ]]; then
    echo "error: notarizing needs SIGN_ID set to a \"Developer ID Application: ...\" identity" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Apple silicon only: Intel Macs aren't supported.
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/DockPlus"

# App icon: every size macOS asks for, made from the one 1024 x 1024 master in Icon/.
# The master follows Apple's icon grid: a rounded tile in the central 824 x 824.
ICON_SRC="Icon/AppIcon-1024.png"
ICONSET_DIR="$(mktemp -d)"
ICONSET="$ICONSET_DIR/AppIcon.iconset"
mkdir "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) "$ICON_SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET_DIR"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>DockPlus</string>
    <key>CFBundleExecutable</key>          <string>DockPlus</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSArchitecturePriority</key>      <array><string>arm64</string></array>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

SIGN_ARGS=(--force --options runtime --sign "$SIGN_ID")
# Notarization requires a secure timestamp; ad-hoc signatures can't have one.
[[ "$SIGN_ID" != "-" ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
# Captured first rather than piped into `grep -q`, which can SIGPIPE codesign under pipefail.
SIGNATURE_INFO="$(codesign --display --verbose "$APP" 2>&1)"
if ! grep -q 'flags=.*runtime' <<<"$SIGNATURE_INFO"; then
    echo "error: $APP is not signed with Hardened Runtime" >&2
    exit 1
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing $APP (usually takes a few minutes)..."
    ZIP_DIR="$(mktemp -d)"
    trap 'rm -rf "$ZIP_DIR"' EXIT # removed even if notarization fails
    ZIP="$ZIP_DIR/DockPlus.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -rf "$ZIP_DIR"
    # Stapling attaches the ticket, so Gatekeeper accepts the app even offline.
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
fi

echo "Built $(pwd)/$APP $VERSION (Hardened Runtime on)"
echo "Next: move it to /Applications and open it from Finder. Don't run the binary inside it"
echo "from Terminal, or macOS will ask to give Terminal these permissions instead. The setup"
echo "guide that opens walks you through Accessibility and (optionally) Screen Recording."
