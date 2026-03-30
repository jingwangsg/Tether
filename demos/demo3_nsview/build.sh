#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY_DIR="$SCRIPT_DIR/ghostty"

if [ ! -f "$GHOSTTY_DIR/libghostty.a" ]; then
  echo "ERROR: ghostty libs not found. Copy from demo1_link/ghostty/ after building."
  exit 1
fi

echo "==> Building demo3..."
swiftc \
  "$SCRIPT_DIR/GhosttyApp.swift" \
  "$SCRIPT_DIR/GhosttyNSView.swift" \
  "$SCRIPT_DIR/AppDelegate.swift" \
  -I "$GHOSTTY_DIR/" \
  -L "$GHOSTTY_DIR/" -lghostty \
  -lc++ \
  -framework Metal -framework AppKit -framework CoreText \
  -framework CoreGraphics -framework Foundation -framework IOKit \
  -framework CoreVideo \
  -import-objc-header "$GHOSTTY_DIR/ghostty.h" \
  -o "$SCRIPT_DIR/demo3"

echo "==> Running demo3 (close window to exit)..."
"$SCRIPT_DIR/demo3"
