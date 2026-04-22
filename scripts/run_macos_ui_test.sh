#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PORT="${PORT:-}"
SESSION_NAME="${SESSION_NAME:-lazy-session}"
DESTINATION="${DESTINATION:-platform=macOS}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tether-ui.XXXXXX")"
DATA_DIR="$TMP_ROOT/data"
HISTORY_SCRIPT="$TMP_ROOT/emit-history.sh"
PID_PATH="/tmp/tether-ui-test-server.pid"
SCRIPT_PID_PATH="/tmp/tether-ui-test-script.pid"
CONFIG_PATH="/tmp/tether-ui-config.json"
CONTROL_PID="$PPID"
SCRIPT_PID="$$"
WATCHDOG_PID=""
XCODEBUILD_PID=""
XCODEBUILD_PID_PATH="$TMP_ROOT/xcodebuild.pid"

cleanup() {
  if [[ -n "${WATCHDOG_PID:-}" ]]; then
    kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$WATCHDOG_PID" >/dev/null 2>&1 || true
    wait "$WATCHDOG_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${XCODEBUILD_PID:-}" ]]; then
    kill "$XCODEBUILD_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$XCODEBUILD_PID" >/dev/null 2>&1 || true
    wait "$XCODEBUILD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -f "$PID_PATH" ]] && [[ "$(cat "$PID_PATH" 2>/dev/null || true)" == "${SERVER_PID:-}" ]]; then
    rm -f "$PID_PATH"
  fi
  if [[ -f "$SCRIPT_PID_PATH" ]] && [[ "$(cat "$SCRIPT_PID_PATH" 2>/dev/null || true)" == "$SCRIPT_PID" ]]; then
    rm -f "$SCRIPT_PID_PATH"
  fi
  rm -f "$CONFIG_PATH"
  rm -f "$XCODEBUILD_PID_PATH"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

if [[ -z "$PORT" ]]; then
  PORT="$(
    python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
  )"
fi

if lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "PORT $PORT is already in use; choose a different PORT" >&2
  exit 1
fi

if [[ -f "$PID_PATH" ]]; then
  PREVIOUS_PID="$(cat "$PID_PATH" 2>/dev/null || true)"
  if [[ -n "$PREVIOUS_PID" ]] && ps -p "$PREVIOUS_PID" >/dev/null 2>&1; then
    kill "$PREVIOUS_PID" >/dev/null 2>&1 || true
    wait "$PREVIOUS_PID" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "$PID_PATH"
fi

if [[ -f "$SCRIPT_PID_PATH" ]]; then
  PREVIOUS_SCRIPT_PID="$(cat "$SCRIPT_PID_PATH" 2>/dev/null || true)"
  if [[ -n "$PREVIOUS_SCRIPT_PID" ]] && ps -p "$PREVIOUS_SCRIPT_PID" >/dev/null 2>&1; then
    kill "$PREVIOUS_SCRIPT_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$PREVIOUS_SCRIPT_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$SCRIPT_PID_PATH"
fi

echo "$SCRIPT_PID" >"$SCRIPT_PID_PATH"

cd "$REPO_ROOT"
cargo build -p tether-server -p tether-client >/dev/null

mkdir -p "$DATA_DIR"
cat >"$HISTORY_SCRIPT" <<'EOF'
#!/bin/sh
prefix=''
j=0
while [ "$j" -lt 128 ]; do
  prefix="${prefix}\033[31m\033[32m\033[33m\033[34m\033[35m\033[36m\033[0m"
  j=$((j + 1))
done
i=0
while [ "$i" -lt 1024 ]; do
  printf '%b' "$prefix"
  printf 'lazy-%06d line for mac lazy loading verification\n' "$i"
  i=$((i + 1))
done
while :; do
  sleep 1
done
EOF
chmod +x "$HISTORY_SCRIPT"

TETHER_DATA_DIR="$DATA_DIR" RUST_LOG=error "$REPO_ROOT/target/debug/tether-server" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >"$PID_PATH"

(
  while :; do
    CONTROL_STATE="$(ps -o stat= -p "$CONTROL_PID" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "$CONTROL_STATE" || "$CONTROL_STATE" == Z* ]]; then
      if [[ -f "$XCODEBUILD_PID_PATH" ]]; then
        XCODEBUILD_PID_VALUE="$(cat "$XCODEBUILD_PID_PATH" 2>/dev/null || true)"
        if [[ -n "$XCODEBUILD_PID_VALUE" ]]; then
          kill "$XCODEBUILD_PID_VALUE" >/dev/null 2>&1 || true
          sleep 1
          kill -9 "$XCODEBUILD_PID_VALUE" >/dev/null 2>&1 || true
        fi
      fi
      if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        sleep 1
        kill -9 "$SERVER_PID" >/dev/null 2>&1 || true
      fi
      rm -f "$PID_PATH" "$SCRIPT_PID_PATH" "$XCODEBUILD_PID_PATH"
      kill -TERM "$SCRIPT_PID" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$SCRIPT_PID" >/dev/null 2>&1 || true
      exit 0
    fi
    sleep 2
  done
) &
WATCHDOG_PID=$!

for _ in $(seq 1 100); do
  if curl -sf "http://127.0.0.1:$PORT/api/info" >/dev/null; then
    break
  fi
  sleep 0.2
done

GROUP_ID="$(
  curl -sf \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"UI Lazy Group\",\"default_cwd\":\"$TMP_ROOT\"}" \
    "http://127.0.0.1:$PORT/api/groups" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
)"

curl -sf \
  -H 'Content-Type: application/json' \
  -d "{\"group_id\":\"$GROUP_ID\",\"name\":\"$SESSION_NAME\",\"command\":\"$HISTORY_SCRIPT\",\"cwd\":\"$TMP_ROOT\"}" \
  "http://127.0.0.1:$PORT/api/sessions" >/dev/null

for _ in $(seq 1 100); do
  SESSIONS_JSON="$(curl -sf "http://127.0.0.1:$PORT/api/sessions" || true)"
  if [[ -n "$SESSIONS_JSON" ]] &&
     printf '%s' "$SESSIONS_JSON" | grep -q "\"name\":\"$SESSION_NAME\"" &&
     printf '%s' "$SESSIONS_JSON" | grep -q '"is_alive":true'; then
    break
  fi
  sleep 0.2
done

python3 - "$CONFIG_PATH" "$PORT" "$SESSION_NAME" <<'PY'
import json, sys
path, port, session_name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"port": port, "session_name": session_name}, f)
PY

XCODEBUILD_ARGS=("$@")
has_test_filter=false
for arg in "${XCODEBUILD_ARGS[@]}"; do
  case "$arg" in
    -only-testing:*|-skip-testing:*)
      has_test_filter=true
      break
      ;;
  esac
done
if [[ "$has_test_filter" == false ]]; then
  XCODEBUILD_ARGS=(
    -only-testing:RunnerUITests/RunnerUITests
    -skip-testing:RunnerTests
    "${XCODEBUILD_ARGS[@]}"
  )
fi

cd "$REPO_ROOT/flutter_app/macos"
TETHER_UI_TEST_SERVER_PORT="$PORT" \
TETHER_UI_TEST_SESSION_NAME="$SESSION_NAME" \
xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination "$DESTINATION" \
  "${XCODEBUILD_ARGS[@]}" &
XCODEBUILD_PID=$!
echo "$XCODEBUILD_PID" >"$XCODEBUILD_PID_PATH"
set +e
wait "$XCODEBUILD_PID"
status=$?
set -e
XCODEBUILD_PID=""
rm -f "$XCODEBUILD_PID_PATH"
exit "$status"
