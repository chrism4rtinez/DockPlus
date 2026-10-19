#!/bin/bash
# Builds DockPlus.app with build.sh, then packages it as DockPlus.dmg next to this script.
#   ./make-dmg.sh                    ad-hoc signed app in an unsigned DMG (fine for personal use)
#   SIGN_ID="Developer ID Application: You (TEAMID)" ./make-dmg.sh
#                                    also signs the DMG with that identity
#   SIGN_ID=... NOTARY_PROFILE=dockplus ./make-dmg.sh
#                                    also notarizes and staples the DMG, so it opens on other
#                                    Macs without a Gatekeeper warning. Create the profile once
#                                    with `xcrun notarytool store-credentials dockplus`.
#
# The DMG opens to DockPlus.app beside an Applications shortcut, so installing is a drag.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP="DockPlus.app"
DMG="DockPlus.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# ditto keeps the code signature and extended attributes intact.
ditto "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "DockPlus" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"

if [[ -n "${SIGN_ID:-}" ]]; then
    codesign --force --sign "$SIGN_ID" "$DMG"
    codesign --verify --strict "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${SIGN_ID:-}" ]]; then
        echo "error: NOTARY_PROFILE needs SIGN_ID set to a Developer ID Application identity" >&2
        exit 1
    fi
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Built $(pwd)/$DMG"
