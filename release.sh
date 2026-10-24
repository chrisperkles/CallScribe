#!/usr/bin/env bash
# Builds a release: signed with the Developer ID, notarized and stapled, in a
# DMG, and listed first in appcast.xml — the feed every installed copy checks
# once a day.
#
#   ./release.sh             build, notarize, sign for Sparkle, update appcast.xml
#   ./release.sh --publish   then put the DMG on a GitHub release and push the feed
#
# NOTES='<ul><li>…</li></ul>' becomes the text in the update window.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CallScribe"
VERSION="$(cat VERSION)"
NOTARY_PROFILE="${NOTARY_PROFILE:-CallScribe}"
APP="build/${APP_NAME}.app"
DIST="dist"
DMG="${DIST}/${APP_NAME}-${VERSION}.dmg"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

# A release is a commit: its build number is the commit count, and the DMG has
# to match what's on GitHub.
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: commit first — the working tree has changes." >&2
    exit 1
fi
if grep -q "<sparkle:shortVersionString>${VERSION}<" appcast.xml 2>/dev/null; then
    echo "ERROR: ${VERSION} is already in appcast.xml — bump VERSION." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
ERROR: no notarization credentials stored as "$NOTARY_PROFILE".

Create an app-specific password at https://account.apple.com ▸ Sign-In and
Security ▸ App-Specific Passwords, then run once (it asks for the password):

  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id <your Apple ID> --team-id AF86JFLJ32
MSG
    exit 1
fi

./build.sh --release
codesign --verify --strict --deep "$APP"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")

rm -rf "$DIST"
mkdir -p "$DIST"

# The app itself is notarized and stapled first, so a copy dragged out of the
# DMG passes Gatekeeper offline too.
ditto -c -k --keepParent "$APP" "$DIST/${APP_NAME}.zip"
echo "Notarizing the app (usually 1–5 minutes)…"
xcrun notarytool submit "$DIST/${APP_NAME}.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$DIST/${APP_NAME}.zip"

# The DMG: the app beside a link to /Applications. Signed, notarized, stapled.
mkdir -p "$DIST/stage"
ditto "$APP" "$DIST/stage/${APP_NAME}.app"
ln -s /Applications "$DIST/stage/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DIST/stage" -fs HFS+ -format ULFO -ov "$DMG"
rm -rf "$DIST/stage"
codesign --force --sign "$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')" --timestamp "$DMG"
echo "Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

./appcast.py "$DMG" "$VERSION" "$BUILD_NUMBER" "${NOTES:-}"
echo "Built $DMG (v${VERSION} build ${BUILD_NUMBER}) and listed it in appcast.xml"

if [ "$PUBLISH" = "0" ]; then
    cat <<NEXT
To publish this build (or start over with git checkout appcast.xml && ./release.sh --publish):
  git push origin HEAD
  gh release create v${VERSION} ${DMG} --target \$(git rev-parse HEAD)
  git commit -m "Appcast: ${VERSION}" appcast.xml && git push origin HEAD
NEXT
    exit 0
fi

# The DMG goes up before the feed points at it.
git push origin HEAD
gh release create "v${VERSION}" "$DMG" --target "$(git rev-parse HEAD)" \
    --title "CallScribe ${VERSION}" --notes "${NOTES:-CallScribe ${VERSION}}"
git add appcast.xml
git commit -m "Appcast: ${VERSION}"
git push origin HEAD
echo "Published ${VERSION}. Installed copies pick it up within a day, or at Check for Updates…"
