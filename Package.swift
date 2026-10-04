// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "AppleLocalAI",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [
    .library(name: "AppleLocalAICore", targets: ["AppleLocalAICore"]),
    .library(name: "AppleLocalAI", targets: ["AppleLocalAI"]),
  ],
  targets: [
    .target(name: "AppleLocalAICore"),
    .target(name: "AppleLocalAI", dependencies: ["AppleLocalAICore"]),
    .testTarget(name: "AppleLocalAICoreTests", dependencies: ["AppleLocalAICore"]),
    .testTarget(name: "AppleLocalAITests", dependencies: ["AppleLocalAI"]),
  ],
  swiftLanguageModes: [.v6]
)
