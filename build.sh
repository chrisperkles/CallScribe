#!/usr/bin/env bash
# Builds CallScribe.app.
#
#   ./build.sh               build, sign for this Mac, install to /Applications
#   ./build.sh --no-install  same, but leave it in build/
#   ./build.sh --release     Developer ID + hardened runtime, for release.sh
set -euo pipefail
cd "$(dirname "$0")"

# The Command Line Tools can ship a newer SDK than their toolchain supports
# (SwiftUI's @State then fails to expand); Xcode's toolchain matches its SDK.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP_NAME="CallScribe"
BUNDLE_ID="at.skyline.CallScribe"
VERSION="$(cat VERSION)"
# Sparkle compares this to decide what's newer, so it only ever grows.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Public half of the Sparkle EdDSA key pair; the private half lives in the
# login keychain and never enters the repository.
SPARKLE_PUBLIC_KEY="$(cat sparkle_public_key)"
FEED_URL="${FEED_URL:-https://raw.githubusercontent.com/chrisperkles/CallScribe/main/appcast.xml}"
APP="build/${APP_NAME}.app"
MODE="${1:-}"

# The speech engine is compiled statically and lives inside the bundle, so the
# finished app has no Homebrew, ffmpeg or Python dependency at runtime.
[ -x vendor/bin/whisper-cli ] || ./vendor-whisper.sh

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp vendor/bin/whisper-cli "$APP/Contents/Resources/bin/whisper-cli"

# The app icon (Resources/AppIcon/README.md): macOS 26 and later draw the
# layered AppIcon.icon, compiled into Assets.car; older macOS the .icns, which
# replaces actool's own fallback because ours has a simplified 16 and 32 px.
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --target-device mac \
    --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -d)/AppIcon.plist" --enable-on-demand-resources NO \
    --development-region en "$PWD/Resources/AppIcon/AppIcon.icon" > /dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle (in-app updates). Its XPC services are for sandboxed apps and its
# headers for building against it: left out.
SPARKLE_SRC=$(find .build/artifacts -type d -name Sparkle.framework -path "*macos*" | head -1)
[ -n "$SPARKLE_SRC" ] || { echo "Sparkle.framework not found in .build/artifacts" >&2; exit 1; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SRC" "$SPARKLE"
for part in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "${SPARKLE:?}/$part" "${SPARKLE:?}/Versions/B/$part"
done

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CallScribe records your microphone so your side of the conversation appears in the transcript.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CallScribe records the audio your Mac is playing so the other side of the call appears in the transcript.</string>
    <key>SUFeedURL</key><string>${FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

if [ "$MODE" = "--release" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    if [ -z "$IDENTITY" ]; then
        cat >&2 <<'MSG'
ERROR: No "Developer ID Application" certificate found.

Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates… ▸ + ▸
Developer ID Application. "Apple Development" certificates cannot be used:
Gatekeeper rejects apps signed with them on other Macs.
MSG
        exit 1
    fi
    SIGN_FLAGS=(--options runtime --timestamp)
else
    # Built on the machine it runs on, so a local signature is all Gatekeeper
    # needs. A real certificate is used when one exists, because ad-hoc
    # signatures change on every build and macOS then re-asks for microphone
    # permission.
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
    SIGN_FLAGS=()   # expanded as ${SIGN_FLAGS[@]+…}: bash 3.2 calls an empty array unbound
fi

# Nested code first, then the framework, then the app itself.
for code in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --sign "${IDENTITY:--}" "$code"
done
codesign --force ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --entitlements CallScribe.entitlements \
    --sign "${IDENTITY:--}" "$APP/Contents/Resources/bin/whisper-cli"
codesign --force ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} --entitlements CallScribe.entitlements \
    --identifier "$BUNDLE_ID" --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP  (v${VERSION} build ${BUILD_NUMBER}, signed as: ${IDENTITY:-ad-hoc})"
[ -z "$MODE" ] || exit 0

osascript -e 'quit app "CallScribe"' 2>/dev/null || true
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$APP" "/Applications/${APP_NAME}.app"

echo "Installed /Applications/${APP_NAME}.app"
