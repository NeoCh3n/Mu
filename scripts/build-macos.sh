#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SCRATCH_DIR="$PROJECT_DIR/.build"
MODULE_CACHE="$SCRATCH_DIR/module-cache"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_DIR="$OUTPUT_DIR/Mu.app"

mkdir -p "$MODULE_CACHE"

env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift build \
    --disable-sandbox \
    --configuration release \
    --scratch-path "$SCRATCH_DIR"

BIN_DIR=$(env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift build \
    --disable-sandbox \
    --configuration release \
    --scratch-path "$SCRATCH_DIR" \
    --show-bin-path)

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/MuApp" "$APP_DIR/Contents/MacOS/Mu"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
