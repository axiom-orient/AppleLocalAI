#!/usr/bin/env python3
"""Test exact, framework-independent source slices without Apple SDK mocks.

This is NOT an AppleLocalAI product build. Production manifests remain Swift 6.4.
Mac target platform guards are intentionally not copied into this isolated test
harness; they are verified separately by real compiler rejection on this host.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "Platforms/macOS"

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new evidence directory")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("NOT_RUN: Swift is not installed")
    manifest: list[str] = []
    with tempfile.TemporaryDirectory(prefix="applelocalai-portable-") as temporary:
        workspace = Path(temporary)
        def add(name: str, files: list[Path], dependencies: list[str], test: bool = False) -> None:
            assert files, name
            category = "Tests" if test else "Sources"
            directory = workspace / category / name
            directory.mkdir(parents=True)
            for source in files:
                target = directory / source.name
                if target.exists():
                    raise ValueError(f"colliding source basename: {source}")
                shutil.copy2(source, target)
                if source.read_bytes() != target.read_bytes():
                    raise ValueError(f"copy mismatch: {source}")
            kind = "testTarget" if test else "target"
            manifest.append(f'.{kind}(name: {json.dumps(name)}, dependencies: {json.dumps(dependencies)})')
        def sources(base: Path) -> list[Path]:
            return sorted(p for p in base.glob("*.swift") if p.name != "PlatformRequirement.swift")
        add("AppleLocalAICore", sources(ROOT / "Sources/AppleLocalAICore"), [])
        # Exercise the concrete request-operation Task owner without substituting
        # Foundation Models. The full AppleLocalAI target remains a native gate.
        add("AppleLocalAI", [ROOT / "Sources/AppleLocalAI" / f for f in [
            "AppleLocalAIError.swift", "SessionOperation.swift"
        ]], ["AppleLocalAICore"])
        add("AppleLocalAITests", [
            ROOT / "Tests/AppleLocalAITests/OperationExecutionTests.swift"
        ], ["AppleLocalAI", "AppleLocalAICore"], True)
        add("AppleLocalAIHost", sources(MAC / "Sources/AppleLocalAIHost"), ["AppleLocalAICore"])
        add("AppleLocalAIWire", sources(MAC / "Sources/AppleLocalAIWire"), ["AppleLocalAIHost"])
        add("AppleLocalAILiteRT", sources(MAC / "Sources/AppleLocalAILiteRT"), [])
        add("AppleLocalAILocalModels", [ROOT / "Backends/Sources/AppleLocalAILocalModels" / f for f in [
            "LocalModelAsset.swift", "LocalModelFileFormat.swift", "ManagedModelAssetStore.swift",
            "LiteRTErrors.swift", "LiteRTGenerationLifecycle.swift"
        ]], [])
        add("AppleLocalAICoreTests", sources(ROOT / "Tests/AppleLocalAICoreTests"), ["AppleLocalAICore"], True)
        add("AppleLocalAIHostTests", [MAC / "Tests/AppleLocalAITests" / f for f in [
            "ConversationStateTests.swift", "LocalModelAssetTests.swift",
            "ModelSelectionPolicyTests.swift", "RemoteCredentialPolicyTests.swift", "RuntimePlanTests.swift"
        ]], ["AppleLocalAIHost", "AppleLocalAICore", "AppleLocalAILocalModels"], True)
        add("AppleLocalAIWireTests", sources(MAC / "Tests/AppleLocalAIWireTests"), ["AppleLocalAIWire"], True)
        add("AppleLocalAILiteRTTests", sources(MAC / "Tests/AppleLocalAILiteRTTests"), ["AppleLocalAILiteRT"], True)
        add("AppleLocalAILocalModelsTests", [
            ROOT / "Backends/Tests/AppleLocalAILocalModelsTests/LiteRTGenerationLifecycleTests.swift",
            ROOT / "Backends/Tests/AppleLocalAILocalModelsTests/ManagedModelAssetStoreTests.swift",
        ], ["AppleLocalAILocalModels"], True)
        package = (
            '// swift-tools-version: 6.2\n'
            'import PackageDescription\n'
            'let package = Package(name: "PortableChecks", platforms: [.macOS("27.0")], targets: [\n'
        )
        package += ',\n'.join(manifest) + '\n], swiftLanguageModes: [.v6])\n'
        (workspace / "Package.swift").write_text(package)
        command = [swift, "test", "--package-path", str(workspace), "--jobs", "2"]
        (output / "scope.txt").write_text(
            "Exact production-source subset and exact selected tests. No native inference adapters, Apple SDKs, "
            "model weights, or HTTP transport compiled. Mac platform guard files deliberately excluded.\n"
            + subprocess.check_output([swift, "--version"], text=True) + "\n" + repr(command) + "\n")
        with (output / "swift-test.log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
        print((output / "swift-test.log").read_text())
        (output / "result.json").write_text(json.dumps({"exit_code": result.returncode, "scope": "portable_source_subset"}) + "\n")
        return result.returncode

if __name__ == "__main__":
    raise SystemExit(main())
