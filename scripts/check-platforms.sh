#!/bin/sh
# Compile only each target's unconditional platform requirement. No SDK or stdlib
# is imported. This proves conditional-compilation rejection, NOT product linkage.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v swiftc >/dev/null 2>&1 || { echo "NOT_RUN: swiftc is required" >&2; exit 69; }
log=$(mktemp)
trap 'rm -f "$log"' EXIT HUP INT TERM
count=0
for gate in "$ROOT"/Platforms/macOS/Sources/*/PlatformRequirement.swift; do
  [ -f "$gate" ] || { echo "FAIL: platform guard missing" >&2; exit 1; }
  for target in arm64-apple-ios27.0 arm64-apple-ios27.0-simulator arm64-apple-macos27.0 x86_64-unknown-linux-gnu; do
    if swiftc -frontend -typecheck -nostdimport -parse-stdlib -target "$target" "$gate" >"$log" 2>&1; then
      [ "$target" = arm64-apple-macos27.0 ] || { cat "$log"; echo "FAIL: admitted $target" >&2; exit 1; }
      echo "PASS guard-only: $(basename "$(dirname "$gate")") $target admitted"
    else
      [ "$target" != arm64-apple-macos27.0 ] || { cat "$log"; exit 1; }
      grep -q 'is macOS-only' "$log" || { cat "$log"; echo "FAIL: unrelated compiler failure" >&2; exit 1; }
      echo "PASS guard-only: $(basename "$(dirname "$gate")") $target rejected"
    fi
    count=$((count + 1))
  done
done
echo "platform-requirements: PASS ($count compiler checks; no Apple SDK product build)"
