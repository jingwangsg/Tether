#!/usr/bin/env bash
# Build and run Demo 1: verify libghostty.a links and ghostty_init() works.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY_DIR="$SCRIPT_DIR/ghostty"

if [ ! -f "$GHOSTTY_DIR/libghostty.a" ]; then
  echo "ERROR: $GHOSTTY_DIR/libghostty.a not found."
  echo "Run scripts/build_libghostty.sh first, then copy the outputs here:"
  echo "  cp flutter_app/macos/Runner/ghostty/libghostty.a demos/demo1_link/ghostty/"
  echo "  cp flutter_app/macos/Runner/ghostty/ghostty.h demos/demo1_link/ghostty/"
  exit 1
fi

echo "==> Building demo1..."
swiftc "$SCRIPT_DIR/main.swift" \
  -I "$GHOSTTY_DIR/" \
  -L "$GHOSTTY_DIR/" -lghostty \
  -lc++ \
  -framework Metal \
  -framework AppKit \
  -framework CoreText \
  -framework CoreGraphics \
  -framework Foundation \
  -framework IOKit \
  -import-objc-header "$GHOSTTY_DIR/ghostty.h" \
  -o "$SCRIPT_DIR/demo1"

echo "==> Running demo1..."
"$SCRIPT_DIR/demo1"
