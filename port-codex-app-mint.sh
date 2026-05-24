#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PATCH_SCRIPT="$PROJECT_DIR/scripts/patch-linux-window-ui.js"
NATIVE_MODULE_PATCH_SCRIPT="$PROJECT_DIR/scripts/patch-native-module-loaders.js"
DESKTOP_TEMPLATE="$PROJECT_DIR/templates/codex-desktop.desktop.in"

OUTPUT_ROOT="${CODEX_PORT_OUTPUT_ROOT:-$PROJECT_DIR/runtime}"
INSTALL_DIR="${CODEX_PORT_INSTALL_DIR:-$OUTPUT_ROOT/codex-app}"
CACHE_DIR="${CODEX_PORT_CACHE_DIR:-$OUTPUT_ROOT/cache}"
WORK_DIR="$(mktemp -d)"

DEFAULT_DMG_PATH="$CACHE_DIR/Codex.dmg"
DMG_PATH=""
DMG_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
ELECTRON_VERSION="${CODEX_ELECTRON_VERSION:-40.0.0}"
DESKTOP_INSTALL_SCOPE="${CODEX_DESKTOP_INSTALL_SCOPE:-system}"
DESKTOP_FILE_PATH=""
SYSTEM_DESKTOP_FILE_PATH="/usr/share/applications/codex-desktop.desktop"
USER_DESKTOP_FILE_PATH="$HOME/.local/share/applications/codex-desktop.desktop"

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
  --skip-desktop-entry       Do not install or refresh the desktop entry.
  --system-desktop-entry     Install to /usr/share/applications (default; requires sudo).
  --user-desktop-entry       Install to ~/.local/share/applications instead.
  -h, --help                 Show this help and exit.

Environment variables:
  CODEX_ELECTRON_VERSION     Override the Electron runtime version (default: 40.0.0).
  CODEX_DMG_URL              Override the upstream DMG URL.
  CODEX_PORT_OUTPUT_ROOT     Override the runtime output root (default: ./runtime).
  CODEX_PORT_INSTALL_DIR     Override the app install directory (default: ./runtime/codex-app).
  CODEX_PORT_CACHE_DIR       Override the cache directory (default: ./runtime/cache).
  CODEX_DESKTOP_FILE_PATH    Override the installed desktop entry path.
  CODEX_DESKTOP_INSTALL_SCOPE  system (default) or user — where to install the .desktop file.
EOF
}

resolve_desktop_file_path() {
  if [ -n "${CODEX_DESKTOP_FILE_PATH:-}" ]; then
    DESKTOP_FILE_PATH="$CODEX_DESKTOP_FILE_PATH"
    return 0
  fi

  case "$DESKTOP_INSTALL_SCOPE" in
    system)
      DESKTOP_FILE_PATH="$SYSTEM_DESKTOP_FILE_PATH"
      ;;
    user)
      DESKTOP_FILE_PATH="$USER_DESKTOP_FILE_PATH"
      ;;
    *)
      error "Invalid CODEX_DESKTOP_INSTALL_SCOPE: $DESKTOP_INSTALL_SCOPE (use system or user)"
      ;;
  esac
}

desktop_entry_needs_root() {
  case "$DESKTOP_FILE_PATH" in
    /usr/*|/usr/local/*) return 0 ;;
    *) return 1 ;;
  esac
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
      --system-desktop-entry)
        DESKTOP_INSTALL_SCOPE=system
        ;;
      --user-desktop-entry)
        DESKTOP_INSTALL_SCOPE=user
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
  mkdir -p "$OUTPUT_ROOT" "$CACHE_DIR"

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

build_native_modules() {
  local extracted_asar_dir="$1"
  local native_build_dir="$WORK_DIR/native-build"
  local better_sqlite3_version=""
  local node_pty_version=""
  local better_sqlite3_binary=""
  local node_pty_binary=""
  local node_pty_spawn_helper=""

  better_sqlite3_version="$(node -p "require('$extracted_asar_dir/node_modules/better-sqlite3/package.json').version" 2>/dev/null || true)"
  node_pty_version="$(node -p "require('$extracted_asar_dir/node_modules/node-pty/package.json').version" 2>/dev/null || true)"

  [ -n "$better_sqlite3_version" ] || error "Could not detect better-sqlite3 version in the app bundle"
  [ -n "$node_pty_version" ] || error "Could not detect node-pty version in the app bundle"

  info "Rebuilding native modules for Linux"
  info "better-sqlite3@$better_sqlite3_version, node-pty@$node_pty_version, electron@$ELECTRON_VERSION"

  mkdir -p "$native_build_dir"
  cd "$native_build_dir"

  cat > package.json <<EOF
{
  "name": "codex-app-linux-native-build",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "electron": "$ELECTRON_VERSION",
    "better-sqlite3": "$better_sqlite3_version",
    "node-pty": "$node_pty_version"
  }
}
EOF

  npm install --ignore-scripts --no-audit --no-fund >&2

  npx --yes @electron/rebuild -v "$ELECTRON_VERSION" --force >&2

  better_sqlite3_binary="$(find "$native_build_dir/node_modules/better-sqlite3" -type f -name 'better_sqlite3.node' | head -n 1 || true)"
  node_pty_binary="$(find "$native_build_dir/node_modules/node-pty" -type f -name 'pty.node' | grep '/build/' | head -n 1 || true)"
  node_pty_spawn_helper="$(find "$native_build_dir/node_modules/node-pty" -type f -name 'spawn-helper' | grep '/build/' | head -n 1 || true)"

  [ -n "$better_sqlite3_binary" ] || error "better-sqlite3 rebuild did not produce better_sqlite3.node"
  [ -n "$node_pty_binary" ] || error "node-pty rebuild did not produce a Linux pty.node"
  [ -n "$node_pty_spawn_helper" ] || warn "node-pty rebuild did not produce spawn-helper; continuing"

  rm -rf "$extracted_asar_dir/node_modules/better-sqlite3" "$extracted_asar_dir/node_modules/node-pty"
  cp -R "$native_build_dir/node_modules/better-sqlite3" "$extracted_asar_dir/node_modules/"
  cp -R "$native_build_dir/node_modules/node-pty" "$extracted_asar_dir/node_modules/"
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

  rm -rf "$extracted_asar_dir/node_modules/sparkle-darwin" 2>/dev/null || true
  find "$extracted_asar_dir" -name 'sparkle.node' -delete 2>/dev/null || true

  build_native_modules "$extracted_asar_dir"

  if [ -f "$NATIVE_MODULE_PATCH_SCRIPT" ]; then
    info "Patching native module loaders for Linux/Electron"
    node "$NATIVE_MODULE_PATCH_SCRIPT" "$extracted_asar_dir" >&2
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

detect_codex_cli() {
  local candidate=""
  local nvm_version=""

  if [ -n "${CODEX_CLI_PATH:-}" ] && [ -x "${CODEX_CLI_PATH}" ]; then
    printf '%s\n' "$CODEX_CLI_PATH"
    return 0
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  if [ -r "$HOME/.nvm/alias/default" ]; then
    nvm_version="$(tr -d '[:space:]' < "$HOME/.nvm/alias/default")"
    candidate="$HOME/.nvm/versions/node/${nvm_version}/bin/codex"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [ -d "$HOME/.nvm/versions/node" ]; then
    while IFS= read -r candidate; do
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$HOME/.nvm/versions/node" -maxdepth 3 -path '*/bin/codex' -type f 2>/dev/null | sort -V -r)
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

mkdir -p "$STATE_DIR" "$LOG_DIR"

resolve_codex_cli() {
  local candidate=""
  local nvm_version=""

  if [ -n "${CODEX_CLI_PATH:-}" ] && [ -x "${CODEX_CLI_PATH}" ]; then
    printf '%s\n' "$CODEX_CLI_PATH"
    return 0
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  if [ -r "$HOME/.nvm/alias/default" ]; then
    nvm_version="$(tr -d '[:space:]' < "$HOME/.nvm/alias/default")"
    candidate="$HOME/.nvm/versions/node/${nvm_version}/bin/codex"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [ -d "$HOME/.nvm/versions/node" ]; then
    while IFS= read -r candidate; do
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$HOME/.nvm/versions/node" -maxdepth 3 -path '*/bin/codex' -type f 2>/dev/null | sort -V -r)
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
    notify-send -u critical "Codex Desktop" "$message"
  fi
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
  if [ ! -d "$WEBVIEW_DIR" ]; then
    return 0
  fi

  clear_stale_webview_pid

  (
    cd "$WEBVIEW_DIR"
    python3 -m http.server 5175 --bind 127.0.0.1 >/dev/null 2>&1
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

  echo "Failed to start the local webview server on port 5175" >&2
  return 1
}

main() {
  local codex_cli_path=""
  local launch_error=""

  codex_cli_path="$(resolve_codex_cli || true)"
  if [ -z "$codex_cli_path" ]; then
    launch_error="Codex CLI not found. Install it first, for example with: npm i -g @openai/codex"
    notify_launch_failure "$launch_error"
    echo "$launch_error" >&2
    exit 1
  fi

  exec >>"$LAUNCHER_LOG_FILE" 2>&1
  echo "Launching Codex Desktop (codex=$codex_cli_path)"

  export CODEX_CLI_PATH="$codex_cli_path"
  export ELECTRON_FORCE_IS_PACKAGED=1
  export NODE_ENV=production
  export CHROME_DESKTOP="${CHROME_DESKTOP:-codex-desktop.desktop}"

  start_webview_server

  exec "$SCRIPT_DIR/electron" \
    --no-sandbox \
    --class=codex-desktop \
    --app-id=codex-desktop \
    --ozone-platform-hint=auto \
    --disable-gpu-sandbox \
    --disable-gpu-compositing \
    --enable-features=WaylandWindowDecorations \
    "$@"
}

main "$@"
EOF

  chmod +x "$INSTALL_DIR/start.sh"
}

trust_desktop_entry() {
  local desktop_file="$1"

  command -v gio >/dev/null 2>&1 || return 0

  if gio set "$desktop_file" metadata::trusted true 2>/dev/null; then
    return 0
  fi

  if command -v dbus-launch >/dev/null 2>&1; then
    dbus-launch gio set "$desktop_file" metadata::trusted true 2>/dev/null && return 0
  fi

  warn "Could not mark desktop entry as trusted; double-click may require 'Allow Launching' in the file manager."
}

install_desktop_entry() {
  local exec_path="$INSTALL_DIR/start.sh"
  local icon_path="$INSTALL_DIR/codex.png"
  local temp_file="$WORK_DIR/codex-desktop.desktop"
  local desktop_dir=""
  local codex_cli_path=""
  local desktop_exec=""

  resolve_desktop_file_path

  [ -x "$exec_path" ] || error "Launcher not found: $exec_path"
  [ -f "$DESKTOP_TEMPLATE" ] || error "Desktop template not found: $DESKTOP_TEMPLATE"

  codex_cli_path="$(detect_codex_cli || true)"
  if [ -n "$codex_cli_path" ]; then
    desktop_exec="env CODEX_CLI_PATH=$codex_cli_path $exec_path"
    info "Desktop Exec will pin CODEX_CLI_PATH=$codex_cli_path"
  else
    desktop_exec="$exec_path"
    warn "Codex CLI not found in PATH; double-click may fail until you run: npm i -g @openai/codex"
  fi

  sed \
    -e "s|__EXEC__|$desktop_exec|g" \
    -e "s|__TRYEXEC__|$exec_path|g" \
    -e "s|__ICON__|$icon_path|g" \
    "$DESKTOP_TEMPLATE" > "$temp_file"

  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$temp_file"
  fi

  desktop_dir="$(dirname "$DESKTOP_FILE_PATH")"

  if desktop_entry_needs_root; then
    command -v sudo >/dev/null 2>&1 || error "Installing $DESKTOP_FILE_PATH requires sudo"
    info "Installing system desktop entry (mode 755): $DESKTOP_FILE_PATH"
    sudo install -D -m 755 "$temp_file" "$DESKTOP_FILE_PATH"
    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
    fi
    if [ -f "$USER_DESKTOP_FILE_PATH" ]; then
      warn "Old user desktop entry still present: $USER_DESKTOP_FILE_PATH (remove it to avoid duplicates)"
    fi
  else
    mkdir -p "$desktop_dir"
    cp "$temp_file" "$DESKTOP_FILE_PATH"
    chmod 755 "$DESKTOP_FILE_PATH"
    trust_desktop_entry "$DESKTOP_FILE_PATH"
    if command -v update-desktop-database >/dev/null 2>&1; then
      update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
    fi
  fi

  info "Desktop entry installed: $DESKTOP_FILE_PATH ($(stat -c '%a' "$DESKTOP_FILE_PATH"))"
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
  gtk-launch codex-desktop

Launch from the app menu, or: gtk-launch codex-desktop
EOF
}

main "$@"
