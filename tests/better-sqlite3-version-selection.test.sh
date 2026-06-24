#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

(
  source <(source_script_without_main)
  assert_equals "12.11.1" "$(resolve_better_sqlite3_build_version "12.9.0" "42.1.0")" "upgrades better-sqlite3 12.9.0 for Electron 42"
  assert_equals "12.11.1" "$(resolve_better_sqlite3_build_version "12.11.1" "42.1.0")" "keeps compatible better-sqlite3 version"
  assert_equals "12.9.0" "$(resolve_better_sqlite3_build_version "12.9.0" "40.0.0")" "does not upgrade older Electron builds"
  CODEX_BETTER_SQLITE3_VERSION="12.10.1"
  assert_equals "12.10.1" "$(resolve_better_sqlite3_build_version "12.9.0" "42.1.0")" "preserves explicit better-sqlite3 override"
)

printf 'better-sqlite3-version-selection tests passed\n'
