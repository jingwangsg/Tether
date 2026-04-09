#!/usr/bin/env bash
# Build a universal libghostty.dylib for macOS from a pinned Ghostty release tag.
# Output: flutter_app/macos/Runner/ghostty/libghostty.dylib
#         flutter_app/macos/Runner/ghostty/ghostty.h
#
# Usage: ./scripts/build_libghostty.sh [--tag <tag>]
set -euo pipefail

GHOSTTY_TAG="${GHOSTTY_TAG:-v1.1.3}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.ghostty_build"
OUT_DIR="$REPO_ROOT/flutter_app/macos/Runner/ghostty"

echo "==> Building libghostty $GHOSTTY_TAG"

# 1. Clone or update Ghostty source
if [ -d "$BUILD_DIR/.git" ]; then
  echo "==> Updating existing Ghostty source..."
  git -C "$BUILD_DIR" fetch --tags
  git -C "$BUILD_DIR" checkout "$GHOSTTY_TAG"
else
  echo "==> Cloning Ghostty $GHOSTTY_TAG..."
  git clone --depth 1 --branch "$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty.git "$BUILD_DIR"
fi

# 2. Build both macOS slices with Zig
cd "$BUILD_DIR"
echo "==> Building arm64 dylib..."
zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=aarch64-macos \
  -Demit-xcframework=false
cp zig-out/lib/libghostty.dylib zig-out/lib/libghostty-arm64.dylib

echo "==> Building x86_64 dylib..."
zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=x86_64-macos \
  -Demit-xcframework=false
cp zig-out/lib/libghostty.dylib zig-out/lib/libghostty-x86_64.dylib

# 3. Copy outputs
mkdir -p "$OUT_DIR"
lipo -create \
  zig-out/lib/libghostty-arm64.dylib \
  zig-out/lib/libghostty-x86_64.dylib \
  -output "$OUT_DIR/libghostty.dylib"
cp include/ghostty.h "$OUT_DIR/ghostty.h"

echo "==> Done. Outputs:"
echo "    $OUT_DIR/libghostty.dylib"
echo "    $OUT_DIR/ghostty.h"
