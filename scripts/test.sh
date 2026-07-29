#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SCRATCH_DIR="$PROJECT_DIR/.build"
MODULE_CACHE="$SCRATCH_DIR/module-cache"

mkdir -p "$MODULE_CACHE"

env \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift test \
    --disable-sandbox \
    --scratch-path "$SCRATCH_DIR"
