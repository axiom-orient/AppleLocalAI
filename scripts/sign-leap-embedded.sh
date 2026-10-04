#!/bin/sh
set -eu

# LeapSDK ships a framework with private inference-engine dylibs nested inside
# it. Xcode signs the outer framework, but iOS requires the nested code to be
# signed with the app identity first.
[ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] || exit 0
[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] || exit 0

FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/LeapSDK.framework"
[ -d "$FRAMEWORK" ] || exit 0

NESTED="${FRAMEWORK}/Frameworks"
if [ -d "$NESTED" ]; then
  find "$NESTED" -type f -name "*.dylib" -print0 |
    while IFS= read -r -d '' dylib; do
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$dylib"
    done
fi

codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$FRAMEWORK"
