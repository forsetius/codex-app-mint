#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -q -- "--disable-gpu-compositing" "$REPO_DIR/port-codex-app-mint.sh"; then
  printf 'FAIL: launcher should not disable GPU compositing because it can leave stale UI layers on Linux\n' >&2
  exit 1
fi

if ! grep -q -- "--disable-gpu-sandbox" "$REPO_DIR/port-codex-app-mint.sh"; then
  printf 'FAIL: launcher should still disable the GPU sandbox for the unpackaged Linux port\n' >&2
  exit 1
fi

printf 'launcher-gpu-flags tests passed\n'
