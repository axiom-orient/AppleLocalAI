#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

developer_dir=${DEVELOPER_DIR-}
if [ -z "$developer_dir" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  developer_dir=/Applications/Xcode.app/Contents/Developer
fi

if [ -n "$developer_dir" ] && [ -x "$developer_dir/usr/bin/xcodebuild" ]; then
  # SwiftPM downloads checksummed Apple XCFrameworks; Android LFS assets are unused.
  export GIT_LFS_SKIP_SMUDGE=1
  export DEVELOPER_DIR="$developer_dir"
  swift_format_bin=$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format
  run_swift() {
    swift_command=$1
    shift
    case "$swift_command" in
      package)
        package_action=$1
        shift
        /usr/bin/xcrun swift package "$package_action" --disable-sandbox "$@"
        ;;
      *)
        /usr/bin/xcrun swift "$swift_command" --disable-sandbox "$@"
        ;;
    esac
  }
else
  echo "Xcode 27 is required for the macOS 27 Foundation Models target." >&2
  echo "Install/select Xcode 27, or set DEVELOPER_DIR to its Contents/Developer path." >&2
  exit 69
fi

xcode_version=$(
  "$developer_dir/usr/bin/xcodebuild" -version | sed -n '1p'
)
case "$xcode_version" in
  "Xcode 27"*) ;;
  *)
    echo "Xcode 27 is required; selected toolchain reported: $xcode_version" >&2
    exit 69
    ;;
esac

module_cache="$root/.build/module-cache"
mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFT_MODULECACHE_PATH="$module_cache"

sh "$root/../../scripts/check-architecture.sh"
run_swift package resolve
run_swift package dump-package >/dev/null
find Sources Tests -name '*.swift' -exec "$swift_format_bin" lint --strict {} +
run_swift test --jobs 1
run_swift build -c release -debug-info-format none --product AppleLocalAIMac
run_swift build -c release -debug-info-format none --product AppleLocalAIConsole
run_swift build -c release -debug-info-format none --product AppleLocalAIProvider
run_swift run AppleLocalAIProvider --config integrations/Provider/provider.example.json --check-config
run_swift run AppleLocalAIConsole status >/dev/null

/usr/bin/xcrun swift -e 'import Foundation; _ = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "integrations/Provider/provider.example.json")))'
/usr/bin/plutil -lint packaging/AppleLocalAIMac/Info.plist >/dev/null
/usr/bin/plutil -lint packaging/AppleLocalAIMac/AppleLocalAIMac.entitlements >/dev/null

echo "macOS 27 checks: PASS"
