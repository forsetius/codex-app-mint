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

assert_equals() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$expected" != "$actual" ]; then
    printf 'FAIL: %s\nExpected: %s\nActual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

run_detection() {
  local package_json="$1"
  local override="${2:-}"

  mkdir -p "$TEMP_DIR/app"
  cp "$package_json" "$TEMP_DIR/app/package.json"

  (
    set -Eeuo pipefail
    source <(source_script_without_main)
    if [ -n "$override" ]; then
      CODEX_ELECTRON_VERSION="$override"
      ELECTRON_VERSION="$CODEX_ELECTRON_VERSION"
    else
      unset CODEX_ELECTRON_VERSION
      ELECTRON_VERSION=""
    fi

    detect_electron_version "$TEMP_DIR/app" >/dev/null
    printf '%s\n' "$ELECTRON_VERSION"
  )
}

cat > "$TEMP_DIR/package-with-electron.json" <<'JSON'
{
  "name": "codex-desktop",
  "devDependencies": {
    "electron": "42.1.0"
  }
}
JSON

detected_version="$(run_detection "$TEMP_DIR/package-with-electron.json")"
assert_equals "42.1.0" "$detected_version" "detects Electron version from app package.json"

overridden_version="$(run_detection "$TEMP_DIR/package-with-electron.json" "41.2.3")"
assert_equals "41.2.3" "$overridden_version" "preserves CODEX_ELECTRON_VERSION override"

printf 'electron-version-detection tests passed\n'
