#!/usr/bin/env bash
# One-shot install for a fresh Mac. Safe to re-run to update.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Checking prerequisites"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are required. Installing — accept the dialog, then re-run this script."
    xcode-select --install
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: swift not found even though the Command Line Tools are installed." >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "==> Installing cmake (needed to compile the speech engine)"
        brew install cmake
    else
        echo "ERROR: cmake is required. Install Homebrew from https://brew.sh then re-run." >&2
        exit 1
    fi
fi

echo "==> Building the speech engine (a few minutes the first time)"
./vendor-whisper.sh

echo "==> Building and installing CallScribe"
./build.sh

echo "==> Launching"
open /Applications/CallScribe.app

cat <<'DONE'

Done. Look for the microphone icon in the menu bar, top right.

Next steps, in the app:
  1. Click the icon and choose a speech model. It downloads once (~550 MB).
  2. Start your first recording. macOS asks for Microphone and audio recording
     permission — both are required.

CallScribe starts automatically with your Mac from now on.
DONE
