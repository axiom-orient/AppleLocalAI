// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AppleLocalAISystem",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    .library(name: "AppleLocalAISystem", targets: ["AppleLocalAISystem"])
  ],
  targets: [
    .target(name: "AppleLocalAISystem"),
    .testTarget(name: "AppleLocalAISystemTests", dependencies: ["AppleLocalAISystem"]),
  ],
  swiftLanguageModes: [.v6]
)
