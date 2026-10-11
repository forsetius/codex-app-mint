#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

(
  source "$REPO_DIR/port-codex-app-mint.sh"
  INSTALL_DIR="$TEMP_DIR/install"
  mkdir -p "$INSTALL_DIR"
  create_launcher
)

cat > "$TEMP_DIR/install/electron" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_CLI_PATH" > "$CODEX_TEST_RESOLVED_CLI_PATH"
EOF
chmod +x "$TEMP_DIR/install/electron"

for node_version in v20.1.0 v22.2.0; do
  codex_cli_path="$TEMP_DIR/home/.nvm/versions/node/$node_version/bin/codex"
  mkdir -p "$(dirname "$codex_cli_path")"
  printf '#!/usr/bin/env bash\n' > "$codex_cli_path"
  chmod +x "$codex_cli_path"
done

mkdir -p "$TEMP_DIR/home/.nvm/alias"
printf '20\n' > "$TEMP_DIR/home/.nvm/alias/default"

env -u CODEX_CLI_PATH \
  HOME="$TEMP_DIR/home" \
  PATH="/usr/bin:/bin" \
  XDG_CACHE_HOME="$TEMP_DIR/cache-default" \
  XDG_STATE_HOME="$TEMP_DIR/state-default" \
  CODEX_TEST_RESOLVED_CLI_PATH="$TEMP_DIR/resolved-default.txt" \
  "$TEMP_DIR/install/start.sh"

expected_default_path="$TEMP_DIR/home/.nvm/versions/node/v20.1.0/bin/codex"
if [ "$(cat "$TEMP_DIR/resolved-default.txt")" != "$expected_default_path" ]; then
  printf 'FAIL: launcher did not resolve the NVM default Codex CLI\n' >&2
  exit 1
fi

printf 'lts/*\n' > "$TEMP_DIR/home/.nvm/alias/default"

env -u CODEX_CLI_PATH \
  HOME="$TEMP_DIR/home" \
  PATH="/usr/bin:/bin" \
  XDG_CACHE_HOME="$TEMP_DIR/cache-fallback" \
  XDG_STATE_HOME="$TEMP_DIR/state-fallback" \
  CODEX_TEST_RESOLVED_CLI_PATH="$TEMP_DIR/resolved-fallback.txt" \
  "$TEMP_DIR/install/start.sh"

expected_fallback_path="$TEMP_DIR/home/.nvm/versions/node/v22.2.0/bin/codex"
if [ "$(cat "$TEMP_DIR/resolved-fallback.txt")" != "$expected_fallback_path" ]; then
  printf 'FAIL: launcher did not fall back to the newest installed NVM Codex CLI\n' >&2
  exit 1
fi

printf 'launcher-cli-resolution tests passed\n'
