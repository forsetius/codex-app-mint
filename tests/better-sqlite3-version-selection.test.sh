#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  source "$REPO_DIR/port-codex-app-mint.sh"
  assert_equals "12.11.1" "$(resolve_better_sqlite3_build_version "12.9.0" "42.1.0")" "upgrades better-sqlite3 12.9.0 for Electron 42"
  assert_equals "12.11.1" "$(resolve_better_sqlite3_build_version "12.11.1" "42.1.0")" "keeps compatible better-sqlite3 version"
  assert_equals "12.9.0" "$(resolve_better_sqlite3_build_version "12.9.0" "40.0.0")" "does not upgrade older Electron builds"
  CODEX_BETTER_SQLITE3_VERSION="12.10.1"
  assert_equals "12.10.1" "$(resolve_better_sqlite3_build_version "12.9.0" "42.1.0")" "preserves explicit better-sqlite3 override"
  if ! version_less_than "22.11.0" "$MINIMUM_NODE_VERSION"; then
    printf 'FAIL: Node.js 22.11.0 should be below the minimum supported version\n' >&2
    exit 1
  fi
  if version_less_than "$MINIMUM_NODE_VERSION" "$MINIMUM_NODE_VERSION"; then
    printf 'FAIL: the minimum supported Node.js version should be accepted\n' >&2
    exit 1
  fi
  assert_equals "@electron/rebuild@4.2.1" "$ELECTRON_REBUILD_PACKAGE" "pins the Electron rebuild tool"
  assert_equals "@electron/asar@4.3.1" "$ASAR_CLI_PACKAGE" "pins the supported ASAR tool"
)

printf 'better-sqlite3-version-selection tests passed\n'
