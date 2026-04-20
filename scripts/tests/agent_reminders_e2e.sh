#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

echo "[1/5] local wrapper + notifier"
cargo test -p tether-server --test terminal_env_test local_session_ --manifest-path "$ROOT/Cargo.toml" -- --nocapture --test-threads=1

echo "[2/5] ssh group + nested ssh"
cargo test -p tether-server --test ssh_session_test ssh_group_command_exports_remote_agent_runtime_before_shell_exec --manifest-path "$ROOT/Cargo.toml" -- --exact
cargo test -p tether-server --lib ensure_remote_agent_bundle_uploads_runtime_assets --manifest-path "$ROOT/Cargo.toml" -- --nocapture
cargo test -p tether-server --test terminal_env_test nested_ --manifest-path "$ROOT/Cargo.toml" -- --nocapture --test-threads=1

echo "[3/5] flutter title precedence"
cd "$ROOT/flutter_app"
flutter test test/session_tab_presentation_test.dart test/session_top_bar_test.dart

echo "[4/5] prepare macos test environment"
flutter build macos --debug --config-only
cd "$ROOT/flutter_app/macos"
pod install

echo "[5/5] native desktop notification bridge"
xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination "platform=macOS" \
  -only-testing:RunnerTests/RunnerTests/testHandleActionPostsDesktopNotificationEvent \
  -only-testing:RunnerTests/RunnerTests/testFocusedSurfaceSuppressesDesktopNotificationDelivery
