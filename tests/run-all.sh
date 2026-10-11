#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

bash -n port-codex-app-mint.sh tests/*.test.sh

for file_path in scripts/*.js tests/*.test.js; do
  node --check "$file_path"
done

for file_path in tests/*.test.sh; do
  bash "$file_path"
done

for file_path in tests/*.test.js; do
  node "$file_path"
done

git diff --check

printf 'All tests passed\n'
