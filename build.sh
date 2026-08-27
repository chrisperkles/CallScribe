#!/usr/bin/env bash
# Builds CallScribe.app and installs it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CallScribe"
BUNDLE_ID="at.skyline.CallScribe"
APP="build/${APP_NAME}.app"
DEST="${1:-/Applications}"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"

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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CallScribe records your microphone so your side of the call appears in the transcript.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CallScribe records the audio your Mac is playing so the other side of the call appears in the transcript.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps the microphone / audio-capture permissions
# across rebuilds; ad-hoc signing works but re-prompts every time.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --deep --options runtime \
    --identifier "$BUNDLE_ID" \
    --sign "${IDENTITY:--}" "$APP"

rm -rf "${DEST}/${APP_NAME}.app"
cp -R "$APP" "${DEST}/${APP_NAME}.app"
echo "Installed ${DEST}/${APP_NAME}.app  (signed as: ${IDENTITY:-ad-hoc})"
