#!/usr/bin/env bash
# Builds a fully static, self-contained whisper-cli (Metal shaders embedded)
# and drops it in vendor/bin/. Build-machine only — shipped inside the .app.
set -euo pipefail
cd "$(dirname "$0")"

WHISPER_TAG="${WHISPER_TAG:-v1.8.4}"
SRC="vendor/whisper.cpp"
OUT="vendor/bin"

command -v cmake >/dev/null || { echo "cmake required: brew install cmake"; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    mkdir -p vendor
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
else
    git -C "$SRC" fetch --depth 1 origin tag "$WHISPER_TAG" --no-tags
    git -C "$SRC" checkout -q "$WHISPER_TAG"
fi

cmake -S "$SRC" -B "$SRC/build-static" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_SERVER=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0

cmake --build "$SRC/build-static" --config Release --target whisper-cli -j"$(sysctl -n hw.ncpu)"

mkdir -p "$OUT"
cp "$SRC/build-static/bin/whisper-cli" "$OUT/whisper-cli"

echo "--- linkage (should be system libs only) ---"
otool -L "$OUT/whisper-cli"
