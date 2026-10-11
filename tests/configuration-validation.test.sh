#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

if (
  source "$REPO_DIR/port-codex-app-mint.sh"
  PROJECT_DIR="$TEMP_DIR/project"
  OUTPUT_ROOT="$TEMP_DIR/runtime"
  INSTALL_DIR="$TEMP_DIR"
  CACHE_DIR="$TEMP_DIR/runtime/cache"
  BUILD_LOG_DIR="$TEMP_DIR/runtime/logs"
  validate_configuration_paths >/dev/null 2>&1
); then
  printf 'FAIL: configuration accepted an install directory containing the project\n' >&2
  exit 1
fi

if (
  source "$REPO_DIR/port-codex-app-mint.sh"
  write_native_build_package_json \
    "$TEMP_DIR/package.json" \
    '42.3.0", "unexpected": "value' \
    '12.11.1' \
    '1.1.0' \
    '2.5.6' >/dev/null 2>&1
); then
  printf 'FAIL: native build manifest accepted a non-semantic Electron version\n' >&2
  exit 1
fi

mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$TEMP_DIR/bin/curl"
printf 'known-good-cache\n' > "$TEMP_DIR/archive.zip"

if (
  source "$REPO_DIR/port-codex-app-mint.sh"
  PATH="$TEMP_DIR/bin:$PATH"
  download_file 'https://example.invalid/archive.zip' "$TEMP_DIR/archive.zip" 'test archive' \
    >/dev/null 2>&1
); then
  printf 'FAIL: failed download unexpectedly succeeded\n' >&2
  exit 1
fi

if [ "$(cat "$TEMP_DIR/archive.zip")" != 'known-good-cache' ]; then
  printf 'FAIL: failed download replaced the existing cached file\n' >&2
  exit 1
fi

if [ -e "$TEMP_DIR/archive.zip.partial" ]; then
  printf 'FAIL: failed download left a partial file\n' >&2
  exit 1
fi

printf 'configuration-validation tests passed\n'
