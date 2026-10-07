#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MAC="$ROOT/Platforms/macOS"
fail() { echo "architecture: FAIL: $*" >&2; exit 1; }
for name in AppleLocalAICore AppleLocalAI; do
[ -d "$ROOT/Sources/$name" ] || fail "missing shared target $name"
done
for name in AppleLocalAILocalModels AppleLocalAILEAP; do
[ -d "$ROOT/Backends/Sources/$name" ] || fail "missing optional target $name"
done
[ -f "$MAC/Package.swift" ] || fail "missing macOS package"
# Every package shares the OS 27 baseline.
while IFS= read -r manifest; do
  case "$manifest" in
    "$ROOT/Package.swift"|"$ROOT/Backends/Package.swift"|"$ROOT/Backends/Sources/AppleLocalAILEAP/Package.swift"|"$MAC/Package.swift") ;;
    *) fail "unexpected SwiftPM manifest: ${manifest#"$ROOT"/}" ;;
  esac
done <<EOF
$(find "$ROOT" \( -name .build -o -name .git \) -prune -o -name Package.swift -print)
EOF

# Package minima are an actual consumption boundary, not a runtime availability check.
for manifest in "$ROOT/Package.swift" "$ROOT/Backends/Package.swift" \
  "$ROOT/Backends/Sources/AppleLocalAILEAP/Package.swift"; do
  grep -Fq '.iOS("27.0")' "$manifest" || fail "default iOS minimum must remain 27: $manifest"
  grep -Fq '.macOS("27.0")' "$manifest" || fail "default macOS minimum must remain 27: $manifest"
done
SYSTEM27_SAMPLE="$ROOT/Examples/SystemModel27/project.yml"
[ -f "$SYSTEM27_SAMPLE" ] || fail "missing independent OS 27 SDK consumer"
grep -Fq 'IPHONEOS_DEPLOYMENT_TARGET: "27.0"' "$SYSTEM27_SAMPLE" \
  || fail "OS 27 consumer minimum changed"
grep -Eq '^[[:space:]]+path: \.\./\.\.[[:space:]]*$' "$SYSTEM27_SAMPLE" \
  || fail "OS 27 consumer must consume the root SDK directly"
grep -Eq '^[[:space:]]+product: AppleLocalAI[[:space:]]*$' "$SYSTEM27_SAMPLE" \
  || fail "OS 27 consumer must use AppleLocalAI"
if grep -n -E 'Compatibility|AppleLocalAISystem([[:space:]]|$)|Backends|AppleLocalAILEAP|AppleLocalAILocalModels|NativeAgent' "$SYSTEM27_SAMPLE"; then
  fail "OS 27 system consumer acquired compatibility or optional runtime dependencies"
fi
# Generated Xcode projects are executable configuration too, not just YAML intent.
python3 - "$ROOT" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
for folder, name, product, package, minimum in [
    ("SystemModel27", "AppleLocalAISystem27Sample", "AppleLocalAI", "../..", "27.0"),
]:
    path = root / "Examples" / folder / (name + ".xcodeproj") / "project.pbxproj"
    objects = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))["objects"].values()
    products = [item["productName"] for item in objects if item["isa"] == "XCSwiftPackageProductDependency"]
    packages = [item["relativePath"] for item in objects if item["isa"] == "XCLocalSwiftPackageReference"]
    remote = [item for item in objects if item["isa"] == "XCRemoteSwiftPackageReference"]
    minima = {item.get("buildSettings", {}).get("IPHONEOS_DEPLOYMENT_TARGET") for item in objects if item["isa"] == "XCBuildConfiguration"}
    minima.discard(None)
    if products != [product] or packages != [package] or remote or minima != {minimum}:
        sys.exit(f"architecture: FAIL: {folder} generated project has wrong dependencies or OS minimum")
PY
if grep -R -n -E 'import[[:space:]]+(AppleLocalAILEAP|AppleLocalAILocalModels|NativeAgent)[[:space:]]*$' "$ROOT/Examples/SystemModel27/Sources"; then
  fail "system consumer imported optional runtime code"
fi
[ ! -e "$MAC/script/check-architecture.sh" ] || fail "retired macOS architecture wrapper was reintroduced"
[ ! -e "$MAC/script/evaluate.sh" ] || fail "retired evaluation wrapper was reintroduced"

LITERT_MODEL="$ROOT/Backends/Sources/AppleLocalAILocalModels/LiteRTLanguageModel.swift"
[ -f "$LITERT_MODEL" ] || fail "canonical LiteRT model source is missing"
! grep -q '^[[:space:]]*public init' "$LITERT_MODEL" \
  || fail "LiteRT direct public model construction bypass was reintroduced"
if grep -R -n 'AppleLocalAILocalModels\.ModelError' "$ROOT/Sources" "$ROOT/Backends/Sources" "$MAC/Sources"; then
  fail "retired namespaced model error alias was reintroduced"
fi
if grep -R -n 'FoundationModelsReadiness' "$MAC/Sources"; then
  fail "retired FoundationModelsReadiness compatibility alias was reintroduced"
fi
# Python bytecode is generated locally and is never a source or verification
# contract. Keep ignored interpreter output out of the checkout as well.
python_cache_path=$(find "$ROOT" \( -name .build -o -name .git -o -name .runtime \) -prune -o \
  -type d -name __pycache__ -print -quit)
[ -z "$python_cache_path" ] || fail "generated Python cache was reintroduced: ${python_cache_path#"$ROOT"/}"
# These were generated verification outputs, never source contracts. Reject the
# files by name anywhere in the repository while ignoring build/checkouts.
for retired_surface_name in source-sha256.json harness-package.swift; do
  retired_surface_path=$(find "$ROOT" \( -name .build -o -name .git \) -prune -o \
    -type f -name "$retired_surface_name" -print -quit)
  [ -z "$retired_surface_path" ] || fail "retired verification artifact was reintroduced: ${retired_surface_path#"$ROOT"/}"
done
# These names belonged only to verification output, not to a runtime or
# persistence contract. Keep the retirement fail-closed in the live tool tree.
if grep -R -n -E 'source-sha256\.json|harness-package\.swift|text_sha256|shasum[[:space:]]+-a[[:space:]]+256' \
  --exclude='check-architecture.sh' "$ROOT/scripts" "$MAC/script"; then
  fail "retired checksum/manifest output surface was reintroduced"
fi
if grep -n 'preconditionFailure' "$ROOT/Sources/AppleLocalAI/AppleLocalAITools.swift"; then
  fail "Simulator Vision tools must not retain a runtime trap"
fi
grep -Eq '^[[:space:]]*\*,[[:space:]]*unavailable,' \
  "$ROOT/Sources/AppleLocalAI/AppleLocalAITools.swift" \
  || fail "Simulator Vision tools must retain a compile-time unavailable contract"
# README and development docs intentionally support direct invocation. Keep
# that contract executable instead of silently relying on `sh`/`python3`.
for tool in "$ROOT"/scripts/*.sh "$ROOT"/scripts/*.py \
  "$MAC"/script/*.sh "$MAC"/script/*.py \
  "$MAC"/integrations/CoreAI/*.sh; do
  [ -f "$tool" ] || continue
  [ -x "$tool" ] || fail "tool is not executable: ${tool#"$ROOT"/}"
done
# Check reachable source/manifest boundaries, not docs or unrelated transitive resolver pins.
if grep -n -E 'Platforms/macOS|AppleLocalAIHost|AppleLocalAIWire|AppleLocalAIProvider|swift-nio|foundation-models-utilities' "$ROOT/Package.swift"; then
  fail "shared package depends on macOS host code"
fi
if grep -R -n -E 'import (AppKit|NIO[A-Za-z]*|AppleLocalAIHost|AppleLocalAIWire|FoundationModelsUtilities)|ChatCompletionsLanguageModel|RemoteLanguageModelConfiguration' "$ROOT/Sources" "$ROOT/Backends/Sources"; then
  fail "macOS host dependency leaked into shared Sources"
fi
if grep -R -n -E 'FileManager|FileHandle|import (FoundationModels|Vision|CoreAI|MLX|LiteRT|LeapSDK)|(^|[^A-Za-z])URL([^A-Za-z]|$)' "$ROOT/Sources/AppleLocalAICore"; then
  fail "runtime/filesystem dependency in pure core"
fi
if grep -R -n -E 'import NativeAgent|NativeAgentProviderLEAP|NativeAgentModelRuntime|NativeAgentArtifactStore' "$ROOT/Sources" "$ROOT/Backends/Sources" "$ROOT/Tests" "$ROOT/Backends/Tests" "$ROOT/Package.swift" "$ROOT/Backends/Package.swift"; then
  fail "standalone runtime acquired a NativeAgent dependency"
fi
# Repository-owned LiteRT adapter derivatives retain their redistribution contract.
NOTICE="$ROOT/NOTICE"
APACHE_LICENSE="$ROOT/LICENSES/Apache-2.0-LiteRT-LM.txt"
[ -f "$NOTICE" ] || fail "missing LiteRT derivative NOTICE"
[ -f "$APACHE_LICENSE" ] || fail "missing Apache-2.0 license for LiteRT derivatives"
for source in $(grep -R -l '^// Copyright 2026 Google LLC' "$ROOT/Backends/Sources/AppleLocalAILocalModels" --include='*.swift'); do
  relative=${source#"$ROOT/"}
  grep -Fq "$relative" "$NOTICE" || fail "NOTICE missing derived source: $relative"
done
grep -q 'path: "../.."' "$MAC/Package.swift" || fail "macOS must depend on repository root"
grep -q '\.macOS("27.0")' "$MAC/Package.swift" || fail "missing macOS 27 minimum"
if grep -q '\.iOS(' "$MAC/Package.swift"; then fail "macOS manifest advertises iOS"; fi
if grep -n -E '#if[[:space:]]+os\(macOS\)' "$ROOT/Package.swift" "$MAC/Package.swift"; then
  fail "manifest host OS is not a target-platform selector"
fi
for target in "$MAC"/Sources/*; do
  [ -d "$target" ] || continue
  gate="$target/PlatformRequirement.swift"
  [ -f "$gate" ] || fail "missing platform guard: $target"
  grep -q '^#if !os(macOS)$' "$gate" || fail "invalid platform guard: $target"
  grep -q '#error(' "$gate" || fail "non-macOS must fail compilation: $target"
done
if grep -R -n -E '#if os\(macOS\) \|\| os\(iOS\)|repoMobileModule|AppleLocalAIiOS' "$MAC/Sources" "$MAC/Package.swift"; then
  fail "old platform/sibling path remains"
fi
[ ! -d "$MAC/Sources/AppleLocalAICore" ] || fail "macOS copied shared core"
[ ! -f "$MAC/Sources/AppleLocalAIFoundationModels/LiteRTLanguageModel.swift" ] || fail "macOS copied LiteRT runtime"
if grep -R -n -E 'LanguageModelSession[[:space:]]*\(' "$MAC/Sources"; then
  fail "macOS constructed a second session authority instead of shared AppleLocalAISession"
fi
if grep -R -n -E 'mlx_lm\.server|litert-lm[[:space:]]+serve' "$ROOT/Sources" "$ROOT/Backends/Sources" "$MAC/Sources"; then
  fail "local inference routed through an external runtime server"
fi
grep -q 'AppleLocalAILocalModels.mlx' "$MAC/Sources/AppleLocalAIFoundationModels/LocalLanguageModels.swift" || fail "missing shared MLX delegation"
grep -q 'AppleLocalAILocalModels.liteRT' "$MAC/Sources/AppleLocalAIFoundationModels/LocalLanguageModels.swift" || fail "missing shared LiteRT delegation"
# Mac presentation must read the canonical provider selection, not a second selector.
if grep -R -n -E 'UserProviderChoice|OnDeviceBackendChoice|appleIntelligenceSnapshot|onDeviceBackend' "$MAC/Sources"; then
  fail "retired duplicate provider selection or stale snapshot reference"
fi
# No writer for these speculative migration keys exists in either reviewed input.
if grep -R -n -E 'provider-settings\.v3|AppleLocalAI\.RemoteLanguageModel' "$MAC/Sources/AppleLocalAIMac/Services"; then
  fail "unproven persistence or credential migration reintroduced"
fi
echo "architecture: PASS (static source/manifest boundaries; not an SDK build)"
