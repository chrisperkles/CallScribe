#!/usr/bin/env bash
# Assembles CallScribe.app.
#
#   ./build.sh              build + install to /Applications, signed for local use
#   ./build.sh --release    sign with Developer ID + hardened runtime (for release.sh)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CallScribe"
BUNDLE_ID="at.skyline.CallScribe"
VERSION="$(cat VERSION)"
# Public half of the Sparkle EdDSA key pair; the private half lives in the
# login keychain and never enters the repository.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(cat sparkle_public_key 2>/dev/null || true)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/${APP_NAME}.app"
RELEASE_MODE=0
[ "${1:-}" = "--release" ] && RELEASE_MODE=1

# The statically linked speech engine ships inside the bundle so users need
# neither Homebrew nor any other install.
[ -x vendor/bin/whisper-cli ] || ./vendor-whisper.sh

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp vendor/bin/whisper-cli "$APP/Contents/Resources/bin/whisper-cli"

# Sparkle powers in-place updates for everyone in the office.
SPARKLE_FRAMEWORK=$(find .build -type d -name Sparkle.framework -path "*artifacts*" | head -1)
[ -n "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework not found — run swift build first"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CallScribe records your microphone so your side of the conversation appears in the transcript.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CallScribe records the audio your Mac is playing so the other side of the call appears in the transcript.</string>
    <key>SUFeedURL</key><string>${APPCAST_URL:-https://skyline.at/callscribe/appcast.xml}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY:-}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

if [ "$RELEASE_MODE" = "1" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    if [ -z "$IDENTITY" ]; then
        cat >&2 <<'MSG'
ERROR: No "Developer ID Application" certificate found.

Create one at https://developer.apple.com/account/resources/certificates
  → + → Developer ID Application → upload a CSR from Keychain Access
  (Keychain Access ▸ Certificate Assistant ▸ Request a Certificate From a
   Certificate Authority ▸ Saved to disk)
Then download the .cer and double-click it to install.

"Apple Development" certificates cannot be used for distribution — apps signed
with them are rejected by Gatekeeper on other Macs.
MSG
        exit 1
    fi
    SIGN_FLAGS=(--options runtime --timestamp --entitlements CallScribe.entitlements)
else
    IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
    SIGN_FLAGS=(--entitlements CallScribe.entitlements)
fi

# Sign inside-out: nested helpers first, then frameworks, then the app itself.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate"
do
    [ -e "$nested" ] && codesign --force "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$nested"
done
codesign --force "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$SPARKLE"
codesign --force "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" \
    "$APP/Contents/Resources/bin/whisper-cli"
codesign --force "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID" --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "Built $APP  (v${VERSION} build ${BUILD_NUMBER}, signed as: ${IDENTITY:-ad-hoc})"

if [ "$RELEASE_MODE" = "0" ]; then
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" "/Applications/${APP_NAME}.app"
    echo "Installed /Applications/${APP_NAME}.app"
fi
