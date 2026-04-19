#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FLUTTER_APP_DIR="$PROJECT_DIR/flutter_app"
BUILD_DIR="$PROJECT_DIR/build"

run_flutter_pub_get() {
  local pub_get_log
  pub_get_log="$(mktemp)"

  if ! flutter pub get >"$pub_get_log" 2>&1; then
    cat "$pub_get_log"
    rm -f "$pub_get_log"
    return 1
  fi

  rm -f "$pub_get_log"
}

read_version() {
  grep '^version:' "$FLUTTER_APP_DIR/pubspec.yaml" | sed 's/version: *//; s/+.*//'
}

main() {
  local version
  local apk_source
  local apk_output

  version="$(read_version)"

  echo "=== Building Android app (Flutter) ==="
  cd "$FLUTTER_APP_DIR"
  run_flutter_pub_get
  flutter build apk --release

  apk_source="$FLUTTER_APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
  apk_output="$BUILD_DIR/tether-${version}-android.apk"

  mkdir -p "$BUILD_DIR"
  cp "$apk_source" "$apk_output"

  echo ""
  echo "=== Build complete ==="
  echo "APK: $apk_output"
  ls -lh "$apk_output"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
