// swift-tools-version: 6.4
import PackageDescription

// Standalone consumer entry point over the canonical LEAP sources.
// The aggregate Backends package uses the same files and excludes this manifest.
let package = Package(
  name: "AppleLocalAILEAP",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [.library(name: "AppleLocalAILEAP", targets: ["AppleLocalAILEAP"])],
  targets: [
    .target(
      name: "AppleLocalAILEAP",
      dependencies: ["LeapSDK"],
      path: ".",
      exclude: ["Package.swift", "README.md"]
    ),
    .binaryTarget(
      name: "LeapSDK",
      url:
        "https://github.com/Liquid4All/leap-sdk/releases/download/v0.10.13-SNAPSHOT/LeapSDK.xcframework.zip",
      checksum: "99abbed6967de43dfa2b3ad03350f4146bf9ab9194a2fbc719d239066e6becc3"
    ),
  ],
  swiftLanguageModes: [.v6]
)
