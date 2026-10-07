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
      dependencies: ["LeapSDK", "inference_engine"],
      path: ".",
      exclude: ["Package.swift", "README.md"]
    ),
    // Keep the engine separate so Xcode embeds and signs it for the consumer.
    .binaryTarget(
      name: "inference_engine",
      url:
        "https://github.com/Liquid4All/leap-sdk/releases/download/v0.11.0-SNAPSHOT/inference_engine.xcframework.zip",
      checksum: "bd8f4ca176afc87713f48d49e24301090882e8a10761b476ebcf8ee2cced2ba2"
    ),
    .binaryTarget(
      name: "LeapSDK",
      url:
        "https://github.com/Liquid4All/leap-sdk/releases/download/v0.11.0-SNAPSHOT/LeapSDK.xcframework.zip",
      checksum: "f837346f81c73ac9f72e5cb115a9b4087a9155ae743cdc365b702361414343ac"
    ),
  ],
  swiftLanguageModes: [.v6]
)
