#!/bin/bash
# Builds DockPlus.app (via build.sh) and wraps it in DockPlus-<version>.dmg: a window with
# the app next to an Applications shortcut, so installing is a single drag.
#   ./make-dmg.sh                    unsigned DMG around an ad-hoc signed app (testing only)
#   SIGN_ID="Developer ID Application: You (TEAMID)" NOTARY_PROFILE=dockplus ./make-dmg.sh
#                                    signed and notarized app inside a signed, notarized and
#                                    stapled DMG, ready to hand to other people
# VERSION and BUILD_NUMBER are passed through to build.sh. The app runs on Apple silicon only.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP="DockPlus.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLUME="DockPlus"
DMG="DockPlus-$VERSION.dmg"
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

WORK="$(mktemp -d)"
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir "$WORK/root"
ditto "$APP" "$WORK/root/$APP"
ln -s /Applications "$WORK/root/Applications"

# Build read-write first so Finder can save the window layout, then compress.
if [[ -d "/Volumes/$VOLUME" ]]; then
    echo "error: a volume named $VOLUME is already mounted; eject it first" >&2
    exit 1
fi
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/root" -fs HFS+ -format UDRW "$WORK/rw.dmg"
hdiutil attach -quiet -noautoopen "$WORK/rw.dmg"

# Window size and icon positions. Finder may ask once to let Terminal control it; if that's
# declined the DMG still works, the icons just aren't arranged.
if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 740, 460}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set position of item "$APP" of container window to {140, 160}
        set position of item "Applications" of container window to {400, 160}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "warning: couldn't arrange the DMG window; continuing with Finder's default layout" >&2
fi

sync
hdiutil detach -quiet "/Volumes/$VOLUME"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

if [[ "$SIGN_ID" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing $DMG..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo "Built $(pwd)/$DMG"
