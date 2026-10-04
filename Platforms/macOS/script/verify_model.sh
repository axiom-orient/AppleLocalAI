#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
runtime=${1-}
asset=${2-}
case "$runtime" in
  system) ;;
  mlx|litert) ;;
  *) echo "usage: $0 system|mlx|litert [/absolute/model-path]" >&2; exit 2 ;;
esac
if [ "$runtime" != system ]; then
  case "$asset" in /*) ;; *) echo "Model path must be absolute" >&2; exit 2 ;; esac
  [ -e "$asset" ] || { echo "Model asset does not exist: $asset" >&2; exit 66; }
fi
: "${APPLELOCALAI_MODEL_PROMPT:?Provide a prompt}"
: "${APPLELOCALAI_MODEL_EXPECTED:?Provide the expected complete response}"
export DEVELOPER_DIR=${DEVELOPER_DIR-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH="$root/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
export GIT_LFS_SKIP_SMUDGE=1
export APPLELOCALAI_RUN_NATIVE_INFERENCE=1
export APPLELOCALAI_MODEL_RUNTIME="$runtime"
if [ "$runtime" != system ]; then
  export APPLELOCALAI_MODEL_PATH="$asset"
else
  unset APPLELOCALAI_MODEL_PATH
fi
mkdir -p "$CLANG_MODULE_CACHE_PATH"
exec /usr/bin/xcrun swift test --disable-sandbox --jobs 2 --filter realNativeModelInference
