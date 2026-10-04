#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 MODEL.aimodel OUTPUT_DIR [iOS|macOS]" >&2
  exit 64
fi

model=$1
output=$2
platform=${3:-iOS}

case "$platform" in
  iOS|macOS) ;;
  *) echo "platform must be iOS or macOS" >&2; exit 64 ;;
esac

[ -f "$model" ] || { echo "model not found: $model" >&2; exit 66; }
mkdir -p "$output"

developer_dir=${DEVELOPER_DIR-}
if [ -z "$developer_dir" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  developer_dir=/Applications/Xcode.app/Contents/Developer
fi
if [ -n "$developer_dir" ]; then
  export DEVELOPER_DIR="$developer_dir"
fi

command -v xcrun >/dev/null 2>&1 || {
  echo "xcrun not found. Install Xcode 27 or the Xcode command-line tools." >&2
  exit 69
}

xcrun --find coreai-build >/dev/null 2>&1 || {
  echo "coreai-build not found. Install the Metal Toolchain from Xcode 27 Components." >&2
  echo "See: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 69
}

exec xcrun coreai-build compile "$model" \
  --platform "$platform" \
  --min-deployment-version 27.0 \
  --output "$output"
