#!/usr/bin/env bash
# Refresh /usr/share/applications/codex-desktop.desktop with a pinned CODEX_CLI_PATH.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="${CODEX_PORT_INSTALL_DIR:-$PROJECT_DIR/runtime/codex-app}"
TEMPLATE="$PROJECT_DIR/templates/codex-desktop.desktop.in"
DESKTOP_FILE_PATH="${CODEX_DESKTOP_FILE_PATH:-/usr/share/applications/codex-desktop.desktop}"

detect_codex_cli() {
  local candidate=""
  local nvm_version=""

  if [ -n "${CODEX_CLI_PATH:-}" ] && [ -x "${CODEX_CLI_PATH}" ]; then
    printf '%s\n' "$CODEX_CLI_PATH"
    return 0
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  if [ -r "$HOME/.nvm/alias/default" ]; then
    nvm_version="$(tr -d '[:space:]' < "$HOME/.nvm/alias/default")"
    candidate="$HOME/.nvm/versions/node/${nvm_version}/bin/codex"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [ -d "$HOME/.nvm/versions/node" ]; then
    while IFS= read -r candidate; do
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$HOME/.nvm/versions/node" -maxdepth 3 -path '*/bin/codex' -type f 2>/dev/null | sort -V -r)
  fi

  for candidate in \
    "$HOME/.local/bin/codex" \
    "$HOME/.local/share/pnpm/codex" \
    /usr/local/bin/codex \
    /usr/bin/codex
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

exec_path="$INSTALL_DIR/start.sh"
icon_path="$INSTALL_DIR/codex.png"
codex_cli_path=""

[ -x "$exec_path" ] || { echo "Missing launcher: $exec_path (run ./port-codex-app-mint.sh first)" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "Missing template: $TEMPLATE" >&2; exit 1; }

codex_cli_path="$(detect_codex_cli || true)"
if [ -z "$codex_cli_path" ]; then
  echo "Codex CLI not found. Install: npm i -g @openai/codex" >&2
  exit 1
fi

desktop_exec="env CODEX_CLI_PATH=$codex_cli_path $exec_path"
temp_file="$(mktemp)"

sed \
  -e "s|__EXEC__|$desktop_exec|g" \
  -e "s|__TRYEXEC__|$exec_path|g" \
  -e "s|__ICON__|$icon_path|g" \
  "$TEMPLATE" > "$temp_file"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$temp_file"
fi

echo "Installing $DESKTOP_FILE_PATH"
echo "  Exec=$desktop_exec"
sudo install -D -m 755 "$temp_file" "$DESKTOP_FILE_PATH"
sudo update-desktop-database "$(dirname "$DESKTOP_FILE_PATH")" 2>/dev/null || true
rm -f "$temp_file"

echo "Done. Double-click or run: gtk-launch codex-desktop"
