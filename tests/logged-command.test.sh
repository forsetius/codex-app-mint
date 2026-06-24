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

set +e
(
  set +e
  source <(source_script_without_main)
  trap - ERR
  run_logged_command "failing test command" "$TEMP_DIR/failing-command.log" bash -c 'printf "first line\n"; printf "last diagnostic\n"; exit 42'
) >"$TEMP_DIR/stdout.txt" 2>"$TEMP_DIR/stderr.txt"
status=$?
set -e

if [ "$status" -ne 42 ]; then
  printf 'FAIL: expected status 42, got %s\n' "$status" >&2
  exit 1
fi

if ! grep -q "failing test command failed" "$TEMP_DIR/stderr.txt"; then
  printf 'FAIL: missing failure label in stderr\n' >&2
  cat "$TEMP_DIR/stderr.txt" >&2
  exit 1
fi

if ! grep -q "$TEMP_DIR/failing-command.log" "$TEMP_DIR/stderr.txt"; then
  printf 'FAIL: missing log path in stderr\n' >&2
  cat "$TEMP_DIR/stderr.txt" >&2
  exit 1
fi

if ! grep -q "last diagnostic" "$TEMP_DIR/stderr.txt"; then
  printf 'FAIL: missing command diagnostics in stderr\n' >&2
  cat "$TEMP_DIR/stderr.txt" >&2
  exit 1
fi

printf 'logged-command tests passed\n'
