#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tether-build-android.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/flutter_app" \
  "$FIXTURE_ROOT/bin"

cp "$REPO_ROOT/scripts/build-android.sh" "$FIXTURE_ROOT/scripts/build-android.sh"

cat > "$FIXTURE_ROOT/flutter_app/pubspec.yaml" <<'EOF'
name: tether
version: 1.2.3+45
EOF

cat > "$FIXTURE_ROOT/bin/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "${FAKE_FLUTTER_LOG:?}"

case "$*" in
  "pub get")
    exit 0
    ;;
  "build apk --release")
    mkdir -p build/app/outputs/flutter-apk
    printf 'apk-bytes' > build/app/outputs/flutter-apk/app-release.apk
    ;;
  *)
    echo "unexpected flutter invocation: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FIXTURE_ROOT/bin/flutter" "$FIXTURE_ROOT/scripts/build-android.sh"

(
  cd "$FIXTURE_ROOT"
  FAKE_FLUTTER_LOG="$FIXTURE_ROOT/flutter.log" PATH="$FIXTURE_ROOT/bin:$PATH" \
    ./scripts/build-android.sh
)

test -f "$FIXTURE_ROOT/build/tether-1.2.3-android.apk"

expected=$'pub get\nbuild apk --release'
actual="$(cat "$FIXTURE_ROOT/flutter.log")"
if [[ "$actual" != "$expected" ]]; then
  echo "unexpected flutter command sequence" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

echo "build-android smoke test passed"
