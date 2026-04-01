#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Building tether-server (Rust) ==="
cd "$PROJECT_DIR"
cargo build --release
SERVER_BIN="$PROJECT_DIR/target/release/tether-server"
echo "Server binary: $SERVER_BIN"

echo ""
echo "=== Building macOS app (Flutter) ==="
cd "$PROJECT_DIR/flutter_app"
flutter pub get
flutter build macos --release
APP_PATH="$PROJECT_DIR/flutter_app/build/macos/Build/Products/Release/Tether.app"

echo ""
echo "=== Packaging macOS installer (.pkg) ==="

VERSION=$(grep '^version:' "$PROJECT_DIR/flutter_app/pubspec.yaml" | sed 's/version: *//; s/+.*//')
echo "Version: $VERSION"

BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/pkg-staging"
PKG_OUTPUT="$BUILD_DIR/tether-${VERSION}-mac.pkg"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/app-payload"
mkdir -p "$STAGING_DIR/server-payload/usr/local/bin"
mkdir -p "$STAGING_DIR/components"

cp -R "$APP_PATH" "$STAGING_DIR/app-payload/Tether.app"
cp "$SERVER_BIN" "$STAGING_DIR/server-payload/usr/local/bin/"

pkgbuild --analyze --root "$STAGING_DIR/app-payload" "$STAGING_DIR/component.plist"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$STAGING_DIR/component.plist"

pkgbuild \
  --root "$STAGING_DIR/app-payload" \
  --component-plist "$STAGING_DIR/component.plist" \
  --identifier "dev.tether.Tether.app" \
  --version "$VERSION" \
  --install-location "/Applications" \
  "$STAGING_DIR/components/tether-app.pkg"

pkgbuild \
  --root "$STAGING_DIR/server-payload" \
  --identifier "dev.tether.Tether.server" \
  --version "$VERSION" \
  --install-location "/" \
  "$STAGING_DIR/components/tether-server.pkg"

cat > "$STAGING_DIR/distribution.xml" <<DISTEOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Tether</title>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default">
            <line choice="dev.tether.Tether.app"/>
            <line choice="dev.tether.Tether.server"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="dev.tether.Tether.app" visible="false">
        <pkg-ref id="dev.tether.Tether.app"/>
    </choice>
    <choice id="dev.tether.Tether.server" visible="false">
        <pkg-ref id="dev.tether.Tether.server"/>
    </choice>
    <pkg-ref id="dev.tether.Tether.app" version="$VERSION" onConclusion="none">tether-app.pkg</pkg-ref>
    <pkg-ref id="dev.tether.Tether.server" version="$VERSION" onConclusion="none">tether-server.pkg</pkg-ref>
</installer-gui-script>
DISTEOF

productbuild \
  --distribution "$STAGING_DIR/distribution.xml" \
  --package-path "$STAGING_DIR/components" \
  "$PKG_OUTPUT"

rm -rf "$STAGING_DIR"

echo ""
echo "=== Build complete ==="
echo "Server: $SERVER_BIN"
echo "App:    $APP_PATH"
echo "Installer: $PKG_OUTPUT"
ls -lh "$PKG_OUTPUT"
