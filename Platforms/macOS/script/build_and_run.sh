#!/usr/bin/env bash
set -euo pipefail

MODE="run"
PRODUCT="app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --console|console)
      PRODUCT="console"
      shift
      ;;
    run|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify)
      MODE="$1"
      shift
      break
      ;;
    --help|-h)
      echo "usage: $0 [--console] [run|debug|logs|telemetry|verify] [arguments...]"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Keep the headless console path convenient for scripts and CI while making
# the default action the actual user-facing macOS app.
if [[ "$PRODUCT" == "app" && "$MODE" == "run" && $# -gt 0 ]]; then
  case "$1" in
    status|ask|vision|vision-tool|structured|dynamic|pcc|remote|help|--help|-h)
      PRODUCT="console"
      ;;
  esac
fi

if [[ "$PRODUCT" == "app" ]]; then
  PRODUCT_NAME="AppleLocalAIMac"
  PROCESS_NAME="AppleLocalAIMac"
else
  PRODUCT_NAME="AppleLocalAIConsole"
  PROCESS_NAME="AppleLocalAIConsole"
fi

XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
if [[ -z "$XCODE_DEVELOPER_DIR" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [[ -z "$XCODE_DEVELOPER_DIR" ]]; then
  XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
fi
if [[ -z "$XCODE_DEVELOPER_DIR" || ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "Xcode 27 is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
  exit 69
fi
if [[ "$("$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" -version | sed -n '1p')" != Xcode\ 27* ]]; then
  echo "Xcode 27 is required; selected developer directory is not Xcode 27." >&2
  exit 69
fi

# SwiftPM downloads checksummed Apple XCFrameworks; Android LFS assets are unused.
export GIT_LFS_SKIP_SMUDGE=1
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

# This is a local development/verification launcher. Xcode 27's SwiftPM
# sandbox cannot be applied inside the managed host, so keep the build path
# explicit and consistent with script/check.sh and script/verify_model.sh.
/usr/bin/xcrun swift build --disable-sandbox --product "$PRODUCT_NAME"
APP_BINARY="$(/usr/bin/xcrun swift build --disable-sandbox --show-bin-path)/$PRODUCT_NAME"

stage_app() {
  local app_bundle="$ROOT_DIR/dist/AppleLocalAI.app"
  rm -rf "$app_bundle"
  mkdir -p "$app_bundle/Contents/MacOS"
  cp "$APP_BINARY" "$app_bundle/Contents/MacOS/$PROCESS_NAME"
  local binary_dir
  binary_dir="$(dirname "$APP_BINARY")"
  for library in "$binary_dir"/*.dylib; do
    [[ -f "$library" ]] && cp "$library" "$app_bundle/Contents/MacOS/"
  done
  mkdir -p "$app_bundle/Contents/Resources"
  for resource_bundle in "$binary_dir"/*.bundle; do
    [[ -d "$resource_bundle" ]] && cp -R "$resource_bundle" "$app_bundle/Contents/Resources/"
  done
  cp "$ROOT_DIR/packaging/AppleLocalAIMac/Info.plist" "$app_bundle/Contents/Info.plist"
  if [[ -n "${APPLELOCALAI_CODESIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --force --deep \
      --sign "$APPLELOCALAI_CODESIGN_IDENTITY" \
      --entitlements "$ROOT_DIR/packaging/AppleLocalAIMac/AppleLocalAIMac.entitlements" \
      "$app_bundle"
  fi
  echo "$app_bundle"
}

case "$MODE" in
  run)
    if [[ "$PRODUCT" == "app" ]]; then
      app_bundle="$(stage_app)"
      /usr/bin/open -n "$app_bundle"
    else
      "$APP_BINARY" "$@"
    fi
    ;;
  debug|--debug)
    /usr/bin/lldb -- "$APP_BINARY" "$@"
    ;;
  logs|--logs)
    if [[ "$PRODUCT" == "app" ]]; then
      app_bundle="$(stage_app)"
      /usr/bin/open -n "$app_bundle"
    else
      "$APP_BINARY" "$@"
    fi
    /usr/bin/log show --style compact --last 1m --predicate "process == \"$PROCESS_NAME\"" || true
    ;;
  telemetry|--telemetry)
    if [[ "$PRODUCT" == "app" ]]; then
      app_bundle="$(stage_app)"
      /usr/bin/open -n "$app_bundle"
    else
      "$APP_BINARY" "$@"
    fi
    /usr/bin/log show --style compact --last 1m --predicate "subsystem == \"com.apple.foundationmodels\"" || true
    ;;
  verify|--verify)
    if [[ "$PRODUCT" == "app" ]]; then
      app_bundle="$(stage_app)"
      /usr/bin/open -n "$app_bundle"
      sleep 2
      pgrep -x "$PROCESS_NAME" >/dev/null
    else
      "$APP_BINARY" status
    fi
    ;;
  *)
    echo "usage: $0 [--console] [run|debug|logs|telemetry|verify] [arguments...]" >&2
    exit 2
    ;;
esac
