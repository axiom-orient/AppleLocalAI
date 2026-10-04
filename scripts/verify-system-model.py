#!/usr/bin/env python3
"""Qualify one isolated Apple-native consumer on an explicitly selected Simulator."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CONSUMERS = {
    26: ("Examples/SystemModel/AppleLocalAISystemSample.xcodeproj",
         "AppleLocalAISystemSample", "APPLE_LOCAL_AI_SYSTEM_INFERENCE_TESTS=1",
         "SystemModelSampleTests/testOptInActualSystemInference()"),
    27: ("Examples/SystemModel27/AppleLocalAISystem27Sample.xcodeproj",
         "AppleLocalAISystem27Sample", "APPLE_LOCAL_AI_SYSTEM27_INFERENCE_TESTS=1",
         "SystemModel27SampleTests/actualLifecycle()"),
}


def read(command, environment):
    return subprocess.check_output(command, env=environment, text=True).strip()


def major(version):
    return int(version.split(".", 1)[0])


def inspect_ios26_sdk(path):
    root = path.expanduser().resolve()
    metadata = json.loads((root / "SDKSettings.json").read_text())
    version = metadata["Version"]
    if major(version) != 26 or not metadata["CanonicalName"].startswith("iphonesimulator"):
        raise ValueError("--sdk-root requires a genuine iOS 26 Simulator SDK, not a Mac/device SDK.")
    framework = root / "System/Library/Frameworks/FoundationModels.framework"
    if not framework.exists():
        raise ValueError("Selected iOS 26 SDK has no FoundationModels framework.")
    return root, metadata


def inference_results(nodes, identifier):
    results = []
    for node in nodes:
        if node.get("nodeType") == "Test Case" and node.get("nodeIdentifier") == identifier:
            results.append(node.get("result", "Unknown"))
        results.extend(inference_results(node.get("children", []), identifier))
    return results


def source_identity(os_version, project):
    package = ROOT / "Compatibility/AppleLocalAISystem" if os_version == 26 else ROOT
    consumer = (ROOT / project).parent
    files = {package / "Package.swift", ROOT / project / "project.pbxproj",
             consumer / "project.yml", Path(__file__).resolve()}
    for directory in (package / "Sources", consumer / "Sources", consumer / "Tests"):
        files.update(directory.rglob("*.swift"))
    files.update((ROOT / project / "xcshareddata/xcschemes").glob("*.xcscheme"))
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(files)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", required=True, type=int, choices=CONSUMERS)
    parser.add_argument("--simulator", required=True, help="Exact Simulator UDID")
    parser.add_argument("--developer-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path,
                        help="New evidence/build directory outside the repository")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--sdk-root", type=Path,
                        help="OS 26 only: original iPhoneSimulator SDK from an official Xcode bundle")
    args = parser.parse_args()
    if args.sdk_root and args.os != 26:
        parser.error("--sdk-root is restricted to the isolated OS 26 experiment.")
    output = args.output.expanduser().resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("Evidence and builds must be outside the source repository.")
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error(f"Use a new output directory to preserve existing evidence: {error}")
    report = {"requestedOS": args.os, "simulator": args.simulator,
              "developerDirectory": str(args.developer_dir),
              "outcome": "NOT_RUN_ENVIRONMENT", "inferenceRequested": False,
              "inferenceVerified": False}
    environment = dict(os.environ, DEVELOPER_DIR=str(args.developer_dir))

    def save():
        temporary = output / "environment-result.json.tmp"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(output / "environment-result.json")

    try:
        host = read(["/usr/bin/sw_vers", "-productVersion"], environment)
        report["hostMacOS"] = host
        report["xcode"] = read(["/usr/bin/xcrun", "xcodebuild", "-version"], environment)
        report["swift"] = read(["/usr/bin/xcrun", "swift", "--version"], environment)
        sdk = read(["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], environment)
        sdk_root = None
        if args.sdk_root:
            sdk_root, sdk_metadata = inspect_ios26_sdk(args.sdk_root)
            report["driverSDK"] = sdk
            report["selectedSDKRoot"] = str(sdk_root)
            report["selectedSDKMetadata"] = sdk_metadata
            sdk = sdk_metadata["Version"]
        report["sdk"] = sdk
        if major(sdk) < args.os:
            raise ValueError(f"SDK {sdk} cannot build the OS {args.os} consumer.")
        devices = json.loads(read(["/usr/bin/xcrun", "simctl", "list", "devices", "available", "--json"], environment))
        runtime_id = next((key for key, items in devices["devices"].items()
                           if any(item["udid"] == args.simulator for item in items)), None)
        runtimes = json.loads(read(["/usr/bin/xcrun", "simctl", "list", "runtimes", "--json"], environment))
        runtime = next((item for item in runtimes["runtimes"]
                        if item["identifier"] == runtime_id and item["isAvailable"]), None)
        if runtime is None or major(runtime["version"]) != args.os:
            raise ValueError("Selected Simulator is unavailable or belongs to a different OS consumer.")
        report["runtime"] = runtime["version"]
        report["runtimeIdentifier"] = runtime_id
        report["hostRuntimeMajorMismatch"] = major(host) != args.os
        # Host metadata is diagnostic. Only real native inference can qualify a
        # mixed-version combination; a mismatch is neither success nor a veto.
        project, scheme, opt_in, inference_test = CONSUMERS[args.os]
        report["project"] = project
        if not (ROOT / project).exists():
            raise ValueError(f"Missing isolated OS {args.os} consumer project.")
        report["sourceSHA256"] = source_identity(args.os, project)
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        report["error"] = str(error)
        save()
        print(f"NOT_RUN_ENVIRONMENT: {error}", file=sys.stderr)
        return 69

    if args.check_only:
        report["outcome"] = "ENVIRONMENT_INSPECTED_NOT_INFERENCE"
        save()
        print("Environment inspected; actual inference was not executed.")
        return 0
    result_bundle = output / "native.xcresult"
    command = ["/usr/bin/xcrun", "xcodebuild", "test", "-project", str(ROOT / project),
               "-scheme", scheme, "-destination", f"platform=iOS Simulator,id={args.simulator}",
               "-derivedDataPath", str(output / "DerivedData"), "-resultBundlePath", str(result_bundle),
               "-parallel-testing-enabled", "NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", opt_in]
    if sdk_root is not None:
        # Public SDKROOT selects the original headers/link libraries; never edit
        # a platform plist or forge the resulting binary's SDK metadata.
        command.append(f"SDKROOT={sdk_root}")
    report["command"] = command
    report["outcome"] = "RUNNING"
    report["inferenceRequested"] = True
    save()
    try:
        with (output / "native-test.log").open("w") as log:
            result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
        report["exitCode"] = result.returncode
        summary = json.loads(read(
            ["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "tests",
             "--path", str(result_bundle), "--format", "json"], environment))
        (output / "native-test-results.json").write_text(json.dumps(summary, indent=2) + "\n")
        observed = inference_results(summary.get("testNodes", []), inference_test)
        report["inferenceTest"] = inference_test
        report["inferenceTestResults"] = observed
        report["inferenceVerified"] = result.returncode == 0 and observed == ["Passed"]
        report["outcome"] = "INFERENCE_PASS" if report["inferenceVerified"] else "FAIL"
        if not report["inferenceVerified"]:
            report["error"] = "The requested real native inference test did not pass; build, skip and admission are not inference proof."
        exit_code = result.returncode or (0 if report["inferenceVerified"] else 70)
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        report["outcome"] = "FAIL"
        report["error"] = str(error)
        exit_code = 70
    save()
    print(f"{report['outcome']}: {output / 'native-test.log'}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
