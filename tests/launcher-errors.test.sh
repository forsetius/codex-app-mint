#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

source_script_without_main() {
  sed '$d' "$REPO_DIR/port-codex-app-mint.sh"
}

(
  source <(source_script_without_main)
  INSTALL_DIR="$TEMP_DIR/install"
  mkdir -p "$INSTALL_DIR"
  create_launcher
)

cat > "$TEMP_DIR/install/electron" <<'EOF'
#!/usr/bin/env bash
printf 'simulated Electron startup failure\n' >&2
exit 42
EOF
chmod +x "$TEMP_DIR/install/electron"

mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODEX_TEST_NOTIFICATION_LOG"
EOF
chmod +x "$TEMP_DIR/bin/notify-send"

mkdir -p "$TEMP_DIR/home-without-cli"
set +e
env -u CODEX_CLI_PATH \
  HOME="$TEMP_DIR/home-without-cli" \
  PATH="$TEMP_DIR/bin:/usr/bin:/bin" \
  CODEX_LAUNCHER_STDERR=1 \
  CODEX_TEST_NOTIFICATION_LOG="$TEMP_DIR/notifications.txt" \
  XDG_CACHE_HOME="$TEMP_DIR/cache-missing-cli" \
  XDG_CONFIG_HOME="$TEMP_DIR/config-missing-cli" \
  XDG_STATE_HOME="$TEMP_DIR/state-missing-cli" \
  "$TEMP_DIR/install/start.sh" > "$TEMP_DIR/missing-cli-stdout.txt" 2> "$TEMP_DIR/missing-cli-stderr.txt"
missing_cli_status=$?
set -e

if [ "$missing_cli_status" -eq 0 ]; then
  printf 'FAIL: launcher accepted a missing Codex CLI\n' >&2
  exit 1
fi

if ! grep -q 'Codex CLI not found' "$TEMP_DIR/notifications.txt"; then
  printf 'FAIL: launcher did not notify about the missing Codex CLI\n' >&2
  exit 1
fi

if ! grep -q 'exec python3 -m http.server' "$TEMP_DIR/install/start.sh"; then
  printf 'FAIL: webview server subshell must exec Python so cleanup targets the server process\n' >&2
  exit 1
fi

mkdir -p "$TEMP_DIR/cache/codex-app-linux"
printf 'oversized old log\n' > "$TEMP_DIR/cache/codex-app-linux/launcher.log"

mkdir -p "$TEMP_DIR/config/Codex"
ln -s "$(hostname)-$$" "$TEMP_DIR/config/Codex/SingletonLock"

set +e
CODEX_CLI_PATH=/bin/true \
CODEX_LAUNCHER_STDERR=1 \
CODEX_TEST_NOTIFICATION_LOG="$TEMP_DIR/notifications.txt" \
PATH="$TEMP_DIR/bin:$PATH" \
XDG_CACHE_HOME="$TEMP_DIR/cache" \
XDG_CONFIG_HOME="$TEMP_DIR/config" \
XDG_STATE_HOME="$TEMP_DIR/state" \
  "$TEMP_DIR/install/start.sh" > "$TEMP_DIR/conflict-stdout.txt" 2> "$TEMP_DIR/conflict-stderr.txt"
conflict_status=$?
set -e

if [ "$conflict_status" -eq 0 ]; then
  printf 'FAIL: launcher accepted a running process from a different installation\n' >&2
  exit 1
fi

if ! grep -q 'different Codex Desktop installation is already running' "$TEMP_DIR/conflict-stderr.txt"; then
  printf 'FAIL: launcher did not explain the conflicting installation\n' >&2
  exit 1
fi

if ! grep -q 'different Codex Desktop installation is already running' "$TEMP_DIR/notifications.txt"; then
  printf 'FAIL: launcher did not notify about the conflicting installation\n' >&2
  exit 1
fi

set +e
CODEX_CLI_PATH=/bin/true \
CODEX_ELECTRON_USER_DATA_PATH="$TEMP_DIR/profile" \
CODEX_LAUNCHER_LOG_MAX_BYTES=1 \
CODEX_LAUNCHER_STDERR=1 \
CODEX_TEST_NOTIFICATION_LOG="$TEMP_DIR/notifications.txt" \
PATH="$TEMP_DIR/bin:$PATH" \
XDG_CACHE_HOME="$TEMP_DIR/cache" \
XDG_STATE_HOME="$TEMP_DIR/state" \
  "$TEMP_DIR/install/start.sh" > "$TEMP_DIR/stdout.txt" 2> "$TEMP_DIR/stderr.txt"
launcher_status=$?
set -e

if [ "$launcher_status" -ne 42 ]; then
  printf 'FAIL: expected launcher status 42, got %s\n' "$launcher_status" >&2
  exit 1
fi

if ! grep -q 'simulated Electron startup failure' "$TEMP_DIR/stderr.txt"; then
  printf 'FAIL: Electron failure was hidden from launcher stderr\n' >&2
  exit 1
fi

if ! grep -q "$TEMP_DIR/cache/codex-app-linux/launcher.log" "$TEMP_DIR/stderr.txt"; then
  printf 'FAIL: launcher did not report its log path\n' >&2
  exit 1
fi

if ! grep -q 'Codex Desktop failed to start (exit code 42)' "$TEMP_DIR/notifications.txt"; then
  printf 'FAIL: launcher did not notify about the Electron startup failure\n' >&2
  exit 1
fi

if [ ! -f "$TEMP_DIR/cache/codex-app-linux/launcher.log.1" ]; then
  printf 'FAIL: launcher did not create a rotated log\n' >&2
  exit 1
fi

if [ "$(wc -c < "$TEMP_DIR/cache/codex-app-linux/launcher.log.1")" -gt 1 ]; then
  printf 'FAIL: launcher did not bound the rotated log size\n' >&2
  exit 1
fi

printf 'launcher-errors tests passed\n'
