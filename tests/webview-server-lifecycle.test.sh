#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
FIRST_LAUNCHER_PID=""

cleanup() {
  if [ -n "$FIRST_LAUNCHER_PID" ]; then
    kill "$FIRST_LAUNCHER_PID" 2>/dev/null || true
    wait "$FIRST_LAUNCHER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

(
  source "$REPO_DIR/port-codex-app-mint.sh"
  INSTALL_DIR="$TEMP_DIR/install"
  mkdir -p "$INSTALL_DIR/content/webview"
  create_launcher
)

cat > "$TEMP_DIR/install/electron" <<'EOF'
#!/usr/bin/env bash
sleep "${CODEX_TEST_ELECTRON_SLEEP_SECONDS:-0}"
EOF
chmod +x "$TEMP_DIR/install/electron"

mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${1:-}" = "-m" ] && [ "${2:-}" = "http.server" ]; then
  exec sleep 30
fi

if [ "${1:-}" = "-c" ]; then
  pid_file="$XDG_STATE_HOME/codex-app-linux/webview.pid"
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
  exit
fi

exit 1
EOF
chmod +x "$TEMP_DIR/bin/python3"

launcher_environment=(
  CODEX_CLI_PATH=/bin/true
  CODEX_ELECTRON_USER_DATA_PATH="$TEMP_DIR/profile"
  HOME="$TEMP_DIR/home"
  PATH="$TEMP_DIR/bin:/usr/bin:/bin"
  XDG_CACHE_HOME="$TEMP_DIR/cache"
  XDG_STATE_HOME="$TEMP_DIR/state"
)

env "${launcher_environment[@]}" \
  CODEX_TEST_ELECTRON_SLEEP_SECONDS=3 \
  "$TEMP_DIR/install/start.sh" &
FIRST_LAUNCHER_PID=$!

webview_pid_file="$TEMP_DIR/state/codex-app-linux/webview.pid"
for i in $(seq 1 50); do
  if [ -s "$webview_pid_file" ]; then
    break
  fi
  sleep 0.1
done

if [ ! -s "$webview_pid_file" ]; then
  printf 'FAIL: first launcher did not record the webview server PID\n' >&2
  cat "$TEMP_DIR/cache/codex-app-linux/launcher.log" >&2 || true
  exit 1
fi

webview_pid="$(cat "$webview_pid_file")"
if ! kill -0 "$webview_pid" 2>/dev/null; then
  printf 'FAIL: first launcher webview server is not running\n' >&2
  exit 1
fi

env "${launcher_environment[@]}" \
  CODEX_TEST_ELECTRON_SLEEP_SECONDS=0 \
  "$TEMP_DIR/install/start.sh"

if ! kill -0 "$webview_pid" 2>/dev/null; then
  printf 'FAIL: second launcher terminated the shared webview server\n' >&2
  exit 1
fi

if [ "$(cat "$webview_pid_file")" != "$webview_pid" ]; then
  printf 'FAIL: second launcher replaced the shared webview server PID\n' >&2
  exit 1
fi

wait "$FIRST_LAUNCHER_PID"
FIRST_LAUNCHER_PID=""

if kill -0 "$webview_pid" 2>/dev/null; then
  printf 'FAIL: first launcher left the webview server running after exit\n' >&2
  exit 1
fi

if [ -e "$webview_pid_file" ]; then
  printf 'FAIL: first launcher left a stale webview PID file\n' >&2
  exit 1
fi

printf 'webview-server-lifecycle tests passed\n'
