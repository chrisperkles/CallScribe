#!/usr/bin/env bash
# Builds CallScribe.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CallScribe"
BUNDLE_ID="at.skyline.CallScribe"
VERSION="1.0.0"
APP="build/${APP_NAME}.app"

# The speech engine is compiled statically and lives inside the bundle, so the
# finished app has no Homebrew, ffmpeg or Python dependency at runtime.
[ -x vendor/bin/whisper-cli ] || ./vendor-whisper.sh

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp vendor/bin/whisper-cli "$APP/Contents/Resources/bin/whisper-cli"

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
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CallScribe records your microphone so your side of the conversation appears in the transcript.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CallScribe records the audio your Mac is playing so the other side of the call appears in the transcript.</string>
</dict>
</plist>
PLIST

# Built on the machine it runs on, so a local signature is all Gatekeeper needs.
# A real certificate is used when one exists, because ad-hoc signatures change
# on every build and macOS then re-asks for microphone permission.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')

codesign --force --entitlements CallScribe.entitlements \
    --sign "${IDENTITY:--}" "$APP/Contents/Resources/bin/whisper-cli"
codesign --force --entitlements CallScribe.entitlements \
    --identifier "$BUNDLE_ID" --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"

osascript -e 'quit app "CallScribe"' 2>/dev/null || true
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$APP" "/Applications/${APP_NAME}.app"

echo "Installed /Applications/${APP_NAME}.app  (v${VERSION}, signed as: ${IDENTITY:-ad-hoc})"
