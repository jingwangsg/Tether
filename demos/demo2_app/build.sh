#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY_DIR="$SCRIPT_DIR/ghostty"

if [ ! -f "$GHOSTTY_DIR/libghostty.a" ]; then
  echo "ERROR: ghostty libs not found. Copy from demos/demo1_link/ghostty/ after building."
  exit 1
fi

echo "==> Building demo2..."
swiftc "$SCRIPT_DIR/AppTest.swift" \
  -I "$GHOSTTY_DIR/" \
  -L "$GHOSTTY_DIR/" -lghostty \
  -lc++ \
  -framework Metal -framework AppKit -framework CoreText \
  -framework CoreGraphics -framework Foundation -framework IOKit \
  -import-objc-header "$GHOSTTY_DIR/ghostty.h" \
  -o "$SCRIPT_DIR/demo2"

echo "==> Running demo2..."
"$SCRIPT_DIR/demo2"
