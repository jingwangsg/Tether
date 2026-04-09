#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PORT="${PORT:-17681}"
SESSION_NAME="${SESSION_NAME:-lazy-session}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tether-ui.XXXXXX")"
DATA_DIR="$TMP_ROOT/data"
HISTORY_SCRIPT="$TMP_ROOT/emit-history.sh"
CONFIG_PATH="/tmp/tether-ui-config.json"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$CONFIG_PATH"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

if lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  kill "$(lsof -tiTCP:"$PORT" -sTCP:LISTEN | head -n 1)" >/dev/null 2>&1 || true
  sleep 1
fi

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

cd "$REPO_ROOT/flutter_app/macos"
xcodebuild test \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=macOS,arch=x86_64,id=B99263B7-7174-54CE-A119-D45333958C9D,name=My Mac' \
  -only-testing:RunnerUITests
