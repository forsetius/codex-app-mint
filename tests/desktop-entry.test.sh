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
  INSTALL_DIR="$TEMP_DIR/install & __ICON__ tools"
  DESKTOP_TEMPLATE="$REPO_DIR/templates/codex-desktop.desktop.in"
  DESKTOP_FILE_PATH="$TEMP_DIR/applications/codex-desktop.desktop"
  mkdir -p "$INSTALL_DIR"
  printf '#!/usr/bin/env bash\n' > "$INSTALL_DIR/start.sh"
  chmod +x "$INSTALL_DIR/start.sh"
  install_desktop_entry
)

if ! grep -Fxq "Exec=\"$TEMP_DIR/install & __ICON__ tools/start.sh\"" "$TEMP_DIR/applications/codex-desktop.desktop"; then
  printf 'FAIL: desktop entry does not contain the launcher Exec path\n' >&2
  exit 1
fi

if ! grep -Fxq "TryExec=$TEMP_DIR/install & __ICON__ tools/start.sh" "$TEMP_DIR/applications/codex-desktop.desktop"; then
  printf 'FAIL: desktop entry does not contain the launcher TryExec path\n' >&2
  exit 1
fi

desktop-file-validate "$TEMP_DIR/applications/codex-desktop.desktop"

if node "$REPO_DIR/scripts/render-desktop-entry.js" \
  "$REPO_DIR/templates/codex-desktop.desktop.in" \
  "$TEMP_DIR/invalid.desktop" \
  "$TEMP_DIR/invalid=executable" \
  "$TEMP_DIR/icon.png" >/dev/null 2>&1; then
  printf 'FAIL: desktop entry renderer accepted an equals sign in the executable path\n' >&2
  exit 1
fi

printf 'desktop-entry tests passed\n'
