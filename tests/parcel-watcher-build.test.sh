#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

assert_file_exists() {
  local file_path="$1"
  local label="$2"

  if [ ! -f "$file_path" ]; then
    printf 'FAIL: %s (%s)\n' "$label" "$file_path" >&2
    exit 1
  fi
}

(
  source "$REPO_DIR/port-codex-app-mint.sh"
  NATIVE_MODULE_COPY_SCRIPT="$REPO_DIR/scripts/copy-node-module-closure.js"

  mkdir -p "$TEMP_DIR/app" "$TEMP_DIR/native-node-modules/@parcel/watcher"
  mkdir -p "$TEMP_DIR/native-node-modules/@parcel/watcher-linux-x64-glibc"
  mkdir -p "$TEMP_DIR/native-node-modules/@parcel/watcher/node_modules/nested-dependency"
  mkdir -p "$TEMP_DIR/native-node-modules/better-sqlite3"
  mkdir -p "$TEMP_DIR/native-node-modules/node-pty"
  mkdir -p "$TEMP_DIR/native-node-modules/picomatch"

  cat > "$TEMP_DIR/app/package.json" <<'JSON'
{
  "dependencies": {
    "@parcel/watcher": "2.5.6"
  }
}
JSON

  parcel_watcher_version="$(detect_declared_dependency_version "$TEMP_DIR/app" "@parcel/watcher")"
  if [ "$parcel_watcher_version" != "2.5.6" ]; then
    printf 'FAIL: expected @parcel/watcher 2.5.6, got %s\n' "$parcel_watcher_version" >&2
    exit 1
  fi

  write_native_build_package_json \
    "$TEMP_DIR/native-package.json" \
    "42.3.0" \
    "12.11.1" \
    "1.1.0" \
    "$parcel_watcher_version"

  node -e '
    const packageJson = require(process.argv[1]);
    if (packageJson.dependencies["@parcel/watcher"] !== "2.5.6") {
      throw new Error("native build manifest is missing @parcel/watcher@2.5.6");
    }
  ' "$TEMP_DIR/native-package.json"

  cat > "$TEMP_DIR/native-node-modules/@parcel/watcher/package.json" <<'JSON'
{
  "name": "@parcel/watcher",
  "dependencies": {
    "picomatch": "4.0.3",
    "nested-dependency": "2.0.0"
  },
  "optionalDependencies": {
    "@parcel/watcher-linux-x64-glibc": "2.5.6",
    "missing-platform-package": "1.0.0"
  }
}
JSON
  printf '{"name":"@parcel/watcher-linux-x64-glibc"}\n' > "$TEMP_DIR/native-node-modules/@parcel/watcher-linux-x64-glibc/package.json"
  printf '{"name":"picomatch"}\n' > "$TEMP_DIR/native-node-modules/picomatch/package.json"
  printf '{"name":"nested-dependency","version":"2.0.0"}\n' > "$TEMP_DIR/native-node-modules/@parcel/watcher/node_modules/nested-dependency/package.json"
  printf 'parcel binary\n' > "$TEMP_DIR/native-node-modules/@parcel/watcher-linux-x64-glibc/watcher.node"
  printf 'sqlite binary\n' > "$TEMP_DIR/native-node-modules/better-sqlite3/better_sqlite3.node"
  printf 'pty binary\n' > "$TEMP_DIR/native-node-modules/node-pty/pty.node"

  install_rebuilt_native_modules "$TEMP_DIR/native-node-modules" "$TEMP_DIR/app/node_modules"

  assert_file_exists "$TEMP_DIR/app/node_modules/@parcel/watcher/package.json" "missing @parcel/watcher package"
  assert_file_exists "$TEMP_DIR/app/node_modules/@parcel/watcher-linux-x64-glibc/watcher.node" "missing Linux watcher binary"
  assert_file_exists "$TEMP_DIR/app/node_modules/picomatch/package.json" "missing transitive watcher dependency"
  assert_file_exists "$TEMP_DIR/app/node_modules/@parcel/watcher/node_modules/nested-dependency/package.json" "missing nested watcher dependency"
  if [ -e "$TEMP_DIR/app/node_modules/nested-dependency" ]; then
    printf 'FAIL: nested dependency was incorrectly flattened into the target node_modules\n' >&2
    exit 1
  fi
)

mkdir -p "$TEMP_DIR/broken-node-modules/root-package"
cat > "$TEMP_DIR/broken-node-modules/root-package/package.json" <<'JSON'
{
  "name": "root-package",
  "dependencies": {
    "missing-required-package": "1.0.0"
  }
}
JSON

if node "$REPO_DIR/scripts/copy-node-module-closure.js" \
  "$TEMP_DIR/broken-node-modules" \
  "$TEMP_DIR/broken-target-node-modules" \
  "root-package" >/dev/null 2>&1; then
  printf 'FAIL: missing required dependency did not fail closure copying\n' >&2
  exit 1
fi

if node "$REPO_DIR/scripts/copy-node-module-closure.js" \
  "$TEMP_DIR/native-node-modules" \
  "$TEMP_DIR/native-node-modules/target" \
  "@parcel/watcher" >/dev/null 2>&1; then
  printf 'FAIL: overlapping source and target node_modules directories were accepted\n' >&2
  exit 1
fi

printf 'parcel-watcher-build tests passed\n'
