#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tether-build-android.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fixture() {
  local fixture="$1"

  mkdir -p "$fixture/scripts" "$fixture/flutter_app" "$fixture/bin"
  cp "$REPO_ROOT/scripts/build-android.sh" "$fixture/scripts/build-android.sh"

  cat > "$fixture/flutter_app/pubspec.yaml" <<'EOF'
name: tether
version: 1.2.3+45
EOF
}

write_flutter_stub() {
  local fixture="$1"
  local mode="$2"

  cat > "$fixture/bin/flutter" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "\$*" >> "$fixture/flutter.log"

case "\$*" in
  "pub get")
    exit 0
    ;;
  "build apk --release")
    if [[ "$mode" == "success" ]]; then
      mkdir -p build/app/outputs/flutter-apk
      printf 'apk-bytes' > build/app/outputs/flutter-apk/app-release.apk
    fi
    ;;
  *)
    echo "unexpected flutter invocation: \$*" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$fixture/bin/flutter" "$fixture/scripts/build-android.sh"
}

run_success_case() {
  local fixture="$TMP_ROOT/success"
  local expected
  local actual

  make_fixture "$fixture"
  write_flutter_stub "$fixture" "success"

  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" ./scripts/build-android.sh
  )

  test -f "$fixture/build/tether-1.2.3-android.apk"

  expected=$'pub get\nbuild apk --release'
  actual="$(cat "$fixture/flutter.log")"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected flutter command sequence" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

run_missing_artifact_case() {
  local fixture="$TMP_ROOT/missing"
  local output

  make_fixture "$fixture"
  write_flutter_stub "$fixture" "missing"

  if output="$(
    cd "$fixture" &&
    PATH="$fixture/bin:$PATH" ./scripts/build-android.sh 2>&1
  )"; then
    echo "expected build-android.sh to fail when the APK is missing" >&2
    exit 1
  fi

  case "$output" in
    *"Missing Android build artifact:"*"app-release.apk"*)
      ;;
    *)
      echo "missing artifact error message did not include the expected path" >&2
      printf 'actual output:\n%s\n' "$output" >&2
      exit 1
      ;;
  esac
}

run_success_case
run_missing_artifact_case

echo "build-android smoke test passed"
