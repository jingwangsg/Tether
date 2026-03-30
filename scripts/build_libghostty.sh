#!/usr/bin/env bash
# Build libghostty.a for macOS aarch64 from a pinned Ghostty release tag.
# Output: flutter_app/macos/Runner/ghostty/libghostty.a
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

# 2. Build with Zig
echo "==> Running zig build libghostty..."
cd "$BUILD_DIR"
zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=aarch64-macos \
  libghostty

# 3. Copy outputs
mkdir -p "$OUT_DIR"
cp zig-out/lib/libghostty.a "$OUT_DIR/libghostty.a"
cp include/ghostty.h "$OUT_DIR/ghostty.h"

echo "==> Done. Outputs:"
echo "    $OUT_DIR/libghostty.a"
echo "    $OUT_DIR/ghostty.h"
