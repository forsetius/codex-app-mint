#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PATCH_SCRIPT="$PROJECT_DIR/scripts/patch-linux-window-ui.js"
NATIVE_MODULE_PATCH_SCRIPT="$PROJECT_DIR/scripts/patch-native-module-loaders.js"
OWL_FEATURES_PATCH_SCRIPT="$PROJECT_DIR/scripts/patch-owl-features-fallback.js"
NATIVE_MODULE_COPY_SCRIPT="$PROJECT_DIR/scripts/copy-node-module-closure.js"
DESKTOP_TEMPLATE="$PROJECT_DIR/templates/codex-desktop.desktop.in"

OUTPUT_ROOT="${CODEX_PORT_OUTPUT_ROOT:-$PROJECT_DIR/runtime}"
INSTALL_DIR="${CODEX_PORT_INSTALL_DIR:-$OUTPUT_ROOT/codex-app}"
CACHE_DIR="${CODEX_PORT_CACHE_DIR:-$OUTPUT_ROOT/cache}"
BUILD_LOG_DIR="$OUTPUT_ROOT/logs"
WORK_DIR="$(mktemp -d)"

DEFAULT_DMG_PATH="$CACHE_DIR/Codex.dmg"
DMG_PATH=""
DMG_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
ELECTRON_VERSION="${CODEX_ELECTRON_VERSION:-}"
DEFAULT_ELECTRON_VERSION="40.0.0"
DESKTOP_FILE_PATH="${CODEX_DESKTOP_FILE_PATH:-$HOME/.local/share/applications/codex-desktop.desktop}"

FRESH_INSTALL=0
INSTALL_DESKTOP_ENTRY=1
SEVEN_ZIP_CMD=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
  echo -e "${GREEN}[INFO]${NC} $*" >&2
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

run_logged_command() {
  local label="$1"
  local log_path="$2"
  local status=0
  shift 2

  mkdir -p "$(dirname "$log_path")"

  if "$@" >"$log_path" 2>&1; then
    return 0
  else
    status=$?
  fi

  warn "$label failed with exit code $status"
  warn "Full log: $log_path"
  warn "Last 80 log lines:"
  tail -n 80 "$log_path" >&2 || true
  return "$status"
}

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

usage() {
  cat <<'EOF'
Usage: ./port-codex-app-mint.sh [OPTIONS]

Create a temporary Linux Mint-compatible local port of Codex App in ./runtime/.
No updater, no system-wide package installation for the app itself.

Options:
  --dmg PATH                 Use an existing Codex.dmg instead of downloading it.
  --fresh                    Remove the generated runtime and cached downloads first.
  --skip-desktop-entry       Do not install or refresh ~/.local/share/applications/codex-desktop.desktop.
  -h, --help                 Show this help and exit.

Environment variables:
  CODEX_ELECTRON_VERSION     Override the Electron runtime version (default: detected from the app bundle, fallback: 40.0.0).
  CODEX_BETTER_SQLITE3_VERSION Override the better-sqlite3 version used for the Linux native rebuild.
  CODEX_DMG_URL              Override the upstream DMG URL.
  CODEX_PORT_OUTPUT_ROOT     Override the runtime output root (default: ./runtime).
  CODEX_PORT_INSTALL_DIR     Override the app install directory (default: ./runtime/codex-app).
  CODEX_PORT_CACHE_DIR       Override the cache directory (default: ./runtime/cache).
  CODEX_DESKTOP_FILE_PATH    Override the installed desktop entry path.
  CODEX_LAUNCHER_LOG_MAX_BYTES Override the launcher log size limit (default: 10485760).
EOF
}

dependency_help() {
  cat <<'EOF'
Required tools are missing.

Install them on Linux Mint / Ubuntu with:
  sudo apt install curl unzip p7zip-full python3 build-essential

Node.js 20+ with npm/npx is also required.
Using nvm is fine as long as `node`, `npm`, and `npx` are available in PATH.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dmg)
        [ "$#" -ge 2 ] || error "--dmg requires a path"
        DMG_PATH="$2"
        shift
        ;;
      --fresh)
        FRESH_INSTALL=1
        ;;
      --skip-desktop-entry)
        INSTALL_DESKTOP_ENTRY=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        ;;
    esac
    shift
  done
}

prepare_dirs() {
  mkdir -p "$OUTPUT_ROOT" "$CACHE_DIR" "$BUILD_LOG_DIR"

  if [ "$FRESH_INSTALL" -eq 1 ]; then
    info "Removing previous runtime directory: $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    rm -f "$DEFAULT_DMG_PATH"
  fi
}

check_deps() {
  local missing=()
  local node_major=""

  [ "$(uname -s)" = "Linux" ] || error "This script is intended to run on Linux."

  for cmd in node npm npx python3 curl unzip make g++ ; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if command -v 7zz >/dev/null 2>&1; then
    SEVEN_ZIP_CMD="7zz"
  elif command -v 7z >/dev/null 2>&1; then
    SEVEN_ZIP_CMD="7z"
  else
    missing+=("7z")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    error "Missing dependencies: ${missing[*]}
$(dependency_help)"
  fi

  node_major="$(node -v | cut -d. -f1 | tr -d v)"
  if [ "$node_major" -lt 20 ]; then
    error "Node.js 20+ is required (found $(node -v))"
  fi

  if "$SEVEN_ZIP_CMD" | head -n 1 | grep -q "16.02"; then
    error "Your 7-zip build is too old to reliably open modern APFS DMGs. Install a newer 7zz binary."
  fi
}

resolve_dmg_path() {
  if [ -n "$DMG_PATH" ]; then
    [ -f "$DMG_PATH" ] || error "Provided DMG not found: $DMG_PATH"
    DMG_PATH="$(realpath "$DMG_PATH")"
    info "Using provided DMG: $DMG_PATH"
    return
  fi

  DMG_PATH="$DEFAULT_DMG_PATH"
  if [ -s "$DMG_PATH" ]; then
    info "Using cached DMG: $DMG_PATH"
    return
  fi

  info "Downloading Codex App DMG from official OpenAI CDN"
  curl -L --progress-bar --connect-timeout 30 --max-time 900 -o "$DMG_PATH" "$DMG_URL"

  [ -s "$DMG_PATH" ] || error "Download failed or produced an empty file: $DMG_PATH"
}

extract_dmg() {
  local extract_dir="$WORK_DIR/dmg-extracted"
  local seven_zip_log="$WORK_DIR/7z.log"
  local seven_zip_status=0
  local app_dir=""

  mkdir -p "$extract_dir"

  if "$SEVEN_ZIP_CMD" x -y -snl "$DMG_PATH" -o"$extract_dir" >"$seven_zip_log" 2>&1; then
    :
  else
    seven_zip_status=$?
  fi

  app_dir="$(find "$extract_dir" -maxdepth 4 -name '*.app' -type d | head -n 1 || true)"
  [ -n "$app_dir" ] || {
    cat "$seven_zip_log" >&2
    error "Could not find a .app bundle after extracting the DMG"
  }

  if [ "$seven_zip_status" -ne 0 ]; then
    warn "7z returned exit code $seven_zip_status but the app bundle was found. Continuing."
  fi

  printf '%s\n' "$app_dir"
}

detect_electron_version() {
  local extracted_asar_dir="$1"
  local detected_electron_version=""

  if [ -n "${CODEX_ELECTRON_VERSION:-}" ]; then
    ELECTRON_VERSION="$CODEX_ELECTRON_VERSION"
    info "Using Electron override: $ELECTRON_VERSION"
    return
  fi

  detected_electron_version="$(node -p "
const packageJson = require('$extracted_asar_dir/package.json');
const candidates = [
  packageJson.devDependencies && packageJson.devDependencies.electron,
  packageJson.dependencies && packageJson.dependencies.electron,
  packageJson.electronVersion,
  packageJson.build && packageJson.build.electronVersion,
];
const version = candidates.find((candidate) => typeof candidate === 'string' && candidate.length > 0);
version ? version.replace(/^[^0-9]*/, '') : '';
" 2>/dev/null || true)"

  if [ -n "$detected_electron_version" ]; then
    ELECTRON_VERSION="$detected_electron_version"
    info "Detected Electron version from app bundle: $ELECTRON_VERSION"
    return
  fi

  ELECTRON_VERSION="$DEFAULT_ELECTRON_VERSION"
  warn "Could not detect Electron version from app bundle; falling back to $ELECTRON_VERSION"
}

version_less_than() {
  local current_version="$1"
  local minimum_version="$2"

  [ "$current_version" != "$minimum_version" ] &&
    [ "$(printf '%s\n%s\n' "$current_version" "$minimum_version" | sort -V | head -n 1)" = "$current_version" ]
}

resolve_better_sqlite3_build_version() {
  local detected_version="$1"
  local electron_version="$2"
  local electron_major="${electron_version%%.*}"
  local detected_major="${detected_version%%.*}"
  local electron_42_minimum_version="12.11.1"

  if [ -n "${CODEX_BETTER_SQLITE3_VERSION:-}" ]; then
    printf '%s\n' "$CODEX_BETTER_SQLITE3_VERSION"
    return
  fi

  if [ "$electron_major" -ge 42 ] &&
    [ "$detected_major" = "12" ] &&
    version_less_than "$detected_version" "$electron_42_minimum_version"; then
    printf '%s\n' "$electron_42_minimum_version"
    return
  fi

  printf '%s\n' "$detected_version"
}

detect_declared_dependency_version() {
  local extracted_asar_dir="$1"
  local dependency_name="$2"

  node -e '
const packageJson = require(process.argv[1]);
const dependencyName = process.argv[2];
const declaredVersion = packageJson.dependencies?.[dependencyName];
if (typeof declaredVersion === "string") {
  process.stdout.write(declaredVersion.replace(/^[^0-9]*/, ""));
}
' "$extracted_asar_dir/package.json" "$dependency_name"
}

write_native_build_package_json() {
  local package_json_path="$1"
  local electron_version="$2"
  local better_sqlite3_version="$3"
  local node_pty_version="$4"
  local parcel_watcher_version="$5"

  cat > "$package_json_path" <<EOF
{
  "name": "codex-app-linux-native-build",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "electron": "$electron_version",
    "better-sqlite3": "$better_sqlite3_version",
    "node-pty": "$node_pty_version",
    "@parcel/watcher": "$parcel_watcher_version"
  }
}
EOF
}

install_rebuilt_native_modules() {
  local source_node_modules_dir="$1"
  local target_node_modules_dir="$2"

  mkdir -p "$target_node_modules_dir"
  rm -rf "$target_node_modules_dir/better-sqlite3" "$target_node_modules_dir/node-pty"
  cp -R "$source_node_modules_dir/better-sqlite3" "$target_node_modules_dir/"
  cp -R "$source_node_modules_dir/node-pty" "$target_node_modules_dir/"
  node "$NATIVE_MODULE_COPY_SCRIPT" \
    "$source_node_modules_dir" \
    "$target_node_modules_dir" \
    "@parcel/watcher"
}

build_native_modules() {
  local extracted_asar_dir="$1"
  local native_build_dir="$WORK_DIR/native-build"
  local better_sqlite3_version=""
  local better_sqlite3_build_version=""
  local node_pty_version=""
  local parcel_watcher_version=""
  local better_sqlite3_binary=""
  local node_pty_binary=""
  local node_pty_spawn_helper=""
  local parcel_watcher_binary=""

  better_sqlite3_version="$(node -p "require('$extracted_asar_dir/node_modules/better-sqlite3/package.json').version" 2>/dev/null || true)"
  node_pty_version="$(node -p "require('$extracted_asar_dir/node_modules/node-pty/package.json').version" 2>/dev/null || true)"
  parcel_watcher_version="$(detect_declared_dependency_version "$extracted_asar_dir" "@parcel/watcher" 2>/dev/null || true)"

  [ -n "$better_sqlite3_version" ] || error "Could not detect better-sqlite3 version in the app bundle"
  [ -n "$node_pty_version" ] || error "Could not detect node-pty version in the app bundle"
  [ -n "$parcel_watcher_version" ] || error "Could not detect @parcel/watcher version in the app bundle"
  better_sqlite3_build_version="$(resolve_better_sqlite3_build_version "$better_sqlite3_version" "$ELECTRON_VERSION")"

  info "Rebuilding native modules for Linux"
  if [ "$better_sqlite3_build_version" != "$better_sqlite3_version" ]; then
    warn "Using better-sqlite3@$better_sqlite3_build_version for Electron $ELECTRON_VERSION; app bundle contains $better_sqlite3_version"
  fi
  info "better-sqlite3@$better_sqlite3_build_version, node-pty@$node_pty_version, @parcel/watcher@$parcel_watcher_version, electron@$ELECTRON_VERSION"

  mkdir -p "$native_build_dir"
  cd "$native_build_dir"

  write_native_build_package_json \
    "$native_build_dir/package.json" \
    "$ELECTRON_VERSION" \
    "$better_sqlite3_build_version" \
    "$node_pty_version" \
    "$parcel_watcher_version"

  run_logged_command \
    "npm install for native module rebuild" \
    "$BUILD_LOG_DIR/native-npm-install.log" \
    npm install --ignore-scripts --no-audit --no-fund

  run_logged_command \
    "electron-rebuild for native modules" \
    "$BUILD_LOG_DIR/electron-rebuild.log" \
    npx --yes @electron/rebuild -v "$ELECTRON_VERSION" --force

  better_sqlite3_binary="$(find "$native_build_dir/node_modules/better-sqlite3" -type f -name 'better_sqlite3.node' | head -n 1 || true)"
  node_pty_binary="$(find "$native_build_dir/node_modules/node-pty" -type f -name 'pty.node' | grep '/build/' | head -n 1 || true)"
  node_pty_spawn_helper="$(find "$native_build_dir/node_modules/node-pty" -type f -name 'spawn-helper' | grep '/build/' | head -n 1 || true)"
  parcel_watcher_binary="$(find "$native_build_dir/node_modules/@parcel" -type f -name '*.node' | head -n 1 || true)"

  [ -n "$better_sqlite3_binary" ] || error "better-sqlite3 rebuild did not produce better_sqlite3.node"
  [ -n "$node_pty_binary" ] || error "node-pty rebuild did not produce a Linux pty.node"
  [ -n "$node_pty_spawn_helper" ] || warn "node-pty rebuild did not produce spawn-helper; continuing"
  [ -n "$parcel_watcher_binary" ] || error "@parcel/watcher install did not produce a Linux native module"

  install_rebuilt_native_modules "$native_build_dir/node_modules" "$extracted_asar_dir/node_modules"
}

patch_asar() {
  local app_dir="$1"
  local resources_dir="$app_dir/Contents/Resources"
  local extracted_asar_dir="$WORK_DIR/app-extracted"

  [ -f "$resources_dir/app.asar" ] || error "app.asar not found in $resources_dir"

  info "Extracting app.asar"
  cd "$WORK_DIR"
  npx --yes asar extract "$resources_dir/app.asar" "$extracted_asar_dir" >&2

  if [ -d "$resources_dir/app.asar.unpacked" ]; then
    cp -R "$resources_dir/app.asar.unpacked" "$WORK_DIR/"
    cp -R "$resources_dir/app.asar.unpacked/." "$extracted_asar_dir/"
  fi

  detect_electron_version "$extracted_asar_dir"

  rm -rf "$extracted_asar_dir/node_modules/sparkle-darwin" 2>/dev/null || true
  find "$extracted_asar_dir" -name 'sparkle.node' -delete 2>/dev/null || true

  build_native_modules "$extracted_asar_dir"

  if [ -f "$NATIVE_MODULE_PATCH_SCRIPT" ]; then
    info "Patching native module loaders for Linux/Electron"
    node "$NATIVE_MODULE_PATCH_SCRIPT" "$extracted_asar_dir" >&2
  fi

  if [ -f "$OWL_FEATURES_PATCH_SCRIPT" ]; then
    info "Patching OWL feature bindings fallback"
    node "$OWL_FEATURES_PATCH_SCRIPT" "$extracted_asar_dir" >&2
  fi

  if [ -f "$PATCH_SCRIPT" ]; then
    info "Applying Linux-specific UI patches"
    node "$PATCH_SCRIPT" "$extracted_asar_dir" >&2
  fi

  info "Repacking app.asar"
  cd "$WORK_DIR"
  rm -rf "$WORK_DIR/app.asar.unpacked"
  npx --yes asar pack \
    "$extracted_asar_dir" \
    "$WORK_DIR/app.asar" \
    --unpack "{*.node,*.so,*.dylib}" \
    --unpack-dir "{node_modules/better-sqlite3,node_modules/node-pty}" >&2
}

download_electron_runtime() {
  local electron_arch=""
  local electron_zip="$CACHE_DIR/electron-v${ELECTRON_VERSION}.zip"
  local electron_url=""

  case "$(uname -m)" in
    x86_64)
      electron_arch="x64"
      ;;
    aarch64)
      electron_arch="arm64"
      ;;
    *)
      error "Unsupported architecture: $(uname -m)"
      ;;
  esac

  electron_url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"

  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"

  if [ ! -s "$electron_zip" ]; then
    info "Downloading Electron runtime v${ELECTRON_VERSION}"
    curl -L --progress-bar --connect-timeout 30 --max-time 900 -o "$electron_zip" "$electron_url"
  else
    info "Using cached Electron runtime archive: $electron_zip"
  fi

  cd "$INSTALL_DIR"
  unzip -qo "$electron_zip"
}

install_app_files() {
  local extracted_asar_dir="$WORK_DIR/app-extracted"
  local icon_source=""

  mkdir -p "$INSTALL_DIR/resources" "$INSTALL_DIR/content/webview"

  cp "$WORK_DIR/app.asar" "$INSTALL_DIR/resources/app.asar"

  if [ -d "$WORK_DIR/app.asar.unpacked" ]; then
    cp -R "$WORK_DIR/app.asar.unpacked" "$INSTALL_DIR/resources/"
  fi

  if [ -d "$extracted_asar_dir/webview" ]; then
    cp -R "$extracted_asar_dir/webview/." "$INSTALL_DIR/content/webview/"
    icon_source="$(find "$INSTALL_DIR/content/webview/assets" -maxdepth 1 -type f -name 'app-*.png' | head -n 1 || true)"
    if [ -n "$icon_source" ]; then
      cp "$icon_source" "$INSTALL_DIR/codex.png"
    fi

    if [ -f "$INSTALL_DIR/content/webview/index.html" ]; then
      sed -i 's/--startup-background: transparent/--startup-background: #1e1e1e/' "$INSTALL_DIR/content/webview/index.html"
    fi
  else
    warn "No webview directory found in the extracted app.asar"
  fi
}

create_launcher() {
  cat > "$INSTALL_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBVIEW_DIR="$SCRIPT_DIR/content/webview"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/codex-app-linux"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-app-linux"
WEBVIEW_PID_FILE="$STATE_DIR/webview.pid"
LAUNCHER_LOG_FILE="$LOG_DIR/launcher.log"
DEFAULT_LAUNCHER_LOG_MAX_BYTES=10485760
LAUNCHER_LOG_MAX_BYTES="${CODEX_LAUNCHER_LOG_MAX_BYTES:-$DEFAULT_LAUNCHER_LOG_MAX_BYTES}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

if [ -t 2 ] || [ "${CODEX_LAUNCHER_STDERR:-0}" = "1" ]; then
  exec 3>&2
else
  exec 3>/dev/null
fi

case "$LAUNCHER_LOG_MAX_BYTES" in
  ''|*[!0-9]*)
    LAUNCHER_LOG_MAX_BYTES="$DEFAULT_LAUNCHER_LOG_MAX_BYTES"
    ;;
esac

trim_launcher_log() {
  local log_path="$1"
  local trimmed_log_path="$log_path.trimmed"

  if [ ! -f "$log_path" ] ||
    [ "$(wc -c < "$log_path")" -le "$LAUNCHER_LOG_MAX_BYTES" ]; then
    return 0
  fi

  tail -c "$LAUNCHER_LOG_MAX_BYTES" "$log_path" > "$trimmed_log_path"
  mv "$trimmed_log_path" "$log_path"
}

trim_launcher_log "$LAUNCHER_LOG_FILE.1"

if [ -f "$LAUNCHER_LOG_FILE" ] &&
  [ "$(wc -c < "$LAUNCHER_LOG_FILE")" -gt "$LAUNCHER_LOG_MAX_BYTES" ]; then
  rm -f "$LAUNCHER_LOG_FILE.1"
  mv "$LAUNCHER_LOG_FILE" "$LAUNCHER_LOG_FILE.1"
  trim_launcher_log "$LAUNCHER_LOG_FILE.1"
fi

exec >>"$LAUNCHER_LOG_FILE" 2>&1

resolve_codex_cli() {
  local candidate=""
  local nvm_default_alias=""
  local nvm_default_version_prefix=""
  local installed_node_version=""
  local nvm_versions_directory="$HOME/.nvm/versions/node"

  if [ -n "${CODEX_CLI_PATH:-}" ] && [ -x "${CODEX_CLI_PATH}" ]; then
    printf '%s\n' "$CODEX_CLI_PATH"
    return 0
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  if [ -r "$HOME/.nvm/alias/default" ]; then
    nvm_default_alias="$(tr -d '[:space:]' < "$HOME/.nvm/alias/default")"
    case "$nvm_default_alias" in
      ''|*/*)
        ;;
      *)
        candidate="$nvm_versions_directory/$nvm_default_alias/bin/codex"
        if [ -x "$candidate" ]; then
          printf '%s\n' "$candidate"
          return 0
        fi

        case "$nvm_default_alias" in
          v*) ;;
          *)
            candidate="$nvm_versions_directory/v$nvm_default_alias/bin/codex"
            if [ -x "$candidate" ]; then
              printf '%s\n' "$candidate"
              return 0
            fi
            ;;
        esac
        ;;
    esac

    nvm_default_version_prefix="${nvm_default_alias#v}"
    case "$nvm_default_version_prefix" in
      ''|*[!0-9.]*)
        ;;
      *)
        while IFS= read -r candidate; do
          installed_node_version="$(basename "$(dirname "$(dirname "$candidate")")")"
          installed_node_version="${installed_node_version#v}"
          case "$installed_node_version" in
            "$nvm_default_version_prefix"|"$nvm_default_version_prefix".*)
              if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
              fi
              ;;
          esac
        done < <(
          find "$nvm_versions_directory" \
            -mindepth 3 \
            -maxdepth 3 \
            -path '*/bin/codex' \
            \( -type f -o -type l \) \
            -print 2>/dev/null | sort -V -r
        )
        ;;
    esac
  fi

  if [ -d "$nvm_versions_directory" ]; then
    while IFS= read -r candidate; do
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(
      find "$nvm_versions_directory" \
        -mindepth 3 \
        -maxdepth 3 \
        -path '*/bin/codex' \
        \( -type f -o -type l \) \
        -print 2>/dev/null | sort -V -r
    )
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

notify_launch_failure() {
  local message="$1"

  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "Codex Desktop" "$message" >/dev/null 2>&1 || true
  fi
}

check_for_conflicting_installation() {
  local default_user_data_directory="${XDG_CONFIG_HOME:-$HOME/.config}/Codex"
  local singleton_lock_path="$default_user_data_directory/SingletonLock"
  local singleton_lock_target=""
  local running_hostname=""
  local running_pid=""
  local running_executable_path=""
  local current_executable_path=""
  local error_message=""

  if [ -n "${CODEX_ELECTRON_USER_DATA_PATH:-}" ] || [ ! -L "$singleton_lock_path" ]; then
    return 0
  fi

  singleton_lock_target="$(readlink "$singleton_lock_path" 2>/dev/null || true)"
  running_hostname="${singleton_lock_target%-*}"
  running_pid="${singleton_lock_target##*-}"
  case "$running_pid" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac

  if [ "$running_hostname" != "$(hostname)" ] || ! kill -0 "$running_pid" 2>/dev/null; then
    return 0
  fi

  running_executable_path="$(readlink "/proc/$running_pid/exe" 2>/dev/null || true)"
  current_executable_path="$(readlink -f "$SCRIPT_DIR/electron" 2>/dev/null || true)"
  if [ -z "$running_executable_path" ] ||
    [ -z "$current_executable_path" ] ||
    [ "$running_executable_path" = "$current_executable_path" ]; then
    return 0
  fi

  error_message="A different Codex Desktop installation is already running (PID $running_pid). Close it before starting this build. Running executable: $running_executable_path"
  echo "$error_message" >&2
  echo "$error_message" >&3
  notify_launch_failure "$error_message"
  return 1
}

clear_stale_webview_pid() {
  if [ ! -f "$WEBVIEW_PID_FILE" ]; then
    return
  fi

  local pid=""
  pid="$(cat "$WEBVIEW_PID_FILE" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$WEBVIEW_PID_FILE"
  fi
}

start_webview_server() {
  local error_message=""

  if [ ! -d "$WEBVIEW_DIR" ]; then
    return 0
  fi

  clear_stale_webview_pid

  (
    cd "$WEBVIEW_DIR"
    exec python3 -m http.server 5175 --bind 127.0.0.1 >/dev/null 2>&1
  ) &

  echo "$!" > "$WEBVIEW_PID_FILE"
  trap 'kill "$(cat "$WEBVIEW_PID_FILE" 2>/dev/null || true)" 2>/dev/null || true; rm -f "$WEBVIEW_PID_FILE"' EXIT

  local attempt=""
  for attempt in $(seq 1 50); do
    if python3 -c "import socket; s=socket.socket(); s.settimeout(0.3); s.connect(('127.0.0.1', 5175)); s.close()" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done

  error_message="Failed to start the local Codex Desktop webview server on port 5175."
  echo "$error_message" >&2
  echo "$error_message" >&3
  notify_launch_failure "$error_message"
  return 1
}

main() {
  local codex_cli_path=""
  local electron_status=0
  local launch_error=""

  codex_cli_path="$(resolve_codex_cli || true)"
  if [ -z "$codex_cli_path" ]; then
    launch_error="Codex CLI not found. Install it first, for example with: npm i -g @openai/codex"
    echo "$launch_error" >&2
    echo "$launch_error" >&3
    notify_launch_failure "$launch_error"
    exit 1
  fi

  export CODEX_CLI_PATH="$codex_cli_path"
  export ELECTRON_FORCE_IS_PACKAGED=1
  export NODE_ENV=production
  export CHROME_DESKTOP="${CHROME_DESKTOP:-codex-desktop.desktop}"

  check_for_conflicting_installation
  start_webview_server

  if "$SCRIPT_DIR/electron" \
      --no-sandbox \
      --class=codex-desktop \
      --app-id=codex-desktop \
      --ozone-platform-hint=auto \
      --disable-gpu-sandbox \
      --enable-features=WaylandWindowDecorations \
      "$@"; then
    return 0
  else
    electron_status=$?
  fi

  launch_error="Codex Desktop failed to start (exit code $electron_status). See $LAUNCHER_LOG_FILE for details."
  notify_launch_failure "$launch_error"
  echo "$launch_error" >&3
  echo "Launcher log: $LAUNCHER_LOG_FILE" >&3
  tail -n 40 "$LAUNCHER_LOG_FILE" >&3 || true
  return "$electron_status"
}

main "$@"
EOF

  chmod +x "$INSTALL_DIR/start.sh"
}

install_desktop_entry() {
  local exec_path="$INSTALL_DIR/start.sh"
  local icon_path="$INSTALL_DIR/codex.png"
  local temp_file="$WORK_DIR/codex-desktop.desktop"

  [ -x "$exec_path" ] || error "Launcher not found: $exec_path"
  [ -f "$DESKTOP_TEMPLATE" ] || error "Desktop template not found: $DESKTOP_TEMPLATE"

  mkdir -p "$(dirname "$DESKTOP_FILE_PATH")"

  sed \
    -e "s|__EXEC__|$exec_path|g" \
    -e "s|__TRYEXEC__|$exec_path|g" \
    -e "s|__ICON__|$icon_path|g" \
    "$DESKTOP_TEMPLATE" > "$temp_file"

  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$temp_file"
  fi

  cp "$temp_file" "$DESKTOP_FILE_PATH"
  info "Desktop entry installed: $DESKTOP_FILE_PATH"
}

main() {
  local extracted_app_dir=""

  parse_args "$@"
  check_deps
  prepare_dirs
  resolve_dmg_path

  extracted_app_dir="$(extract_dmg)"
  patch_asar "$extracted_app_dir"
  download_electron_runtime
  install_app_files
  create_launcher

  if [ "$INSTALL_DESKTOP_ENTRY" -eq 1 ]; then
    install_desktop_entry
  fi

  cat >&2 <<EOF

============================================
Temporary Codex App Linux port is ready
============================================
Launcher:      $INSTALL_DIR/start.sh
Desktop file:  $DESKTOP_FILE_PATH
Runtime dir:   $INSTALL_DIR

You can start it with:
  $INSTALL_DIR/start.sh
EOF
}

main "$@"
