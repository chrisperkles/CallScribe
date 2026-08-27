#!/usr/bin/env bash
# Produces a notarized, drag-to-install DMG plus the Sparkle appcast that pushes
# it to everyone who already has CallScribe.
#
#   ./release.sh            build, sign, notarize, staple, write appcast
#   ./release.sh --no-notarize   skip notarization (local smoke test only)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CallScribe"
VERSION="$(cat VERSION)"
DIST="dist"
DMG="${DIST}/${APP_NAME}-${VERSION}.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-CallScribe}"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

./build.sh --release

rm -rf "$DIST/stage" "$DMG"
mkdir -p "$DIST/stage"
cp -R "build/${APP_NAME}.app" "$DIST/stage/"
ln -s /Applications "$DIST/stage/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DIST/stage" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DIST/stage"
echo "Created $DMG"

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = "1" ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat >&2 <<MSG
ERROR: No notarization credentials stored under profile "$NOTARY_PROFILE".

Create an app-specific password at https://account.apple.com ▸ Sign-In and
Security ▸ App-Specific Passwords, then run once:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "chris@skyline.at" \\
      --team-id "<YOUR_TEAM_ID>" \\
      --password "<app-specific-password>"

Your Team ID is at https://developer.apple.com/account ▸ Membership.
MSG
        exit 1
    fi

    echo "Submitting to Apple for notarization (usually 1-5 minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "Notarized and stapled."
fi

# Sparkle appcast: signs the DMG with the private EdDSA key from the keychain.
GENERATE_APPCAST=$(find .build -name generate_appcast -type f | head -1)
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://skyline.at/callscribe}"
"$GENERATE_APPCAST" --download-url-prefix "${DOWNLOAD_BASE}/" \
    --link "${DOWNLOAD_BASE}/" "$DIST"

echo
echo "Ready to publish — upload both files to ${DOWNLOAD_BASE}/ :"
echo "  $DMG"
echo "  ${DIST}/appcast.xml"
echo
echo "Existing installs check that appcast daily and will offer ${VERSION} automatically."
