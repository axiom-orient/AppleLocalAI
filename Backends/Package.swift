// swift-tools-version: 6.4
import PackageDescription

// Optional runtimes are deliberately outside the Apple Intelligence build graph.
let package = Package(
  name: "AppleLocalAIBackends",
  platforms: [.macOS("27.0"), .iOS("27.0")],
  products: [
    .library(name: "AppleLocalAILocalModels", targets: ["AppleLocalAILocalModels"]),
    .library(name: "AppleLocalAILEAP", targets: ["AppleLocalAILEAP"]),
  ],
  dependencies: [
    .package(name: "AppleLocalAI", path: ".."),
    .package(
      url: "https://github.com/apple/coreai-models",
      revision: "7359dbcf6c3babb4fbfadfd015ffcc1cb6d87420"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03"
    ),
    // Xcode 27's iOS Metal compiler requires the thread address-space fixes
    // present after the 0.31.6 tag.
    .package(
      url: "https://github.com/ml-explore/mlx-swift",
      revision: "901941965d82e4a216d4d117231d847d194c563d"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers",
      exact: "1.3.4"
    ),
    .package(
      url: "https://github.com/google-ai-edge/LiteRT-LM",
      exact: "0.17.1"
    ),
  ],
  targets: [
    .target(
      name: "AppleLocalAILocalModels",
      dependencies: [
        .product(name: "CoreAILM", package: "coreai-models"),
        .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "LiteRTLM", package: "LiteRT-LM"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    ),
    .target(
      name: "AppleLocalAILEAP",
      dependencies: [
        "LeapSDK"
      ],
      exclude: ["Package.swift", "README.md"]
    ),
    // Keep the native boundary explicit: AppleLocalAILEAP owns the Swift
    // lifecycle and downloads, while this is the only third-party LEAP seam.
    .binaryTarget(
      name: "LeapSDK",
      url:
        "https://github.com/Liquid4All/leap-sdk/releases/download/v0.10.13-SNAPSHOT/LeapSDK.xcframework.zip",
      checksum: "99abbed6967de43dfa2b3ad03350f4146bf9ab9194a2fbc719d239066e6becc3"
    ),
    .testTarget(
      name: "AppleLocalAILEAPTests",
      dependencies: ["AppleLocalAILEAP", .product(name: "AppleLocalAI", package: "AppleLocalAI")]
    ),
    .testTarget(name: "AppleLocalAILocalModelsTests", dependencies: ["AppleLocalAILocalModels"]),
  ],
  swiftLanguageModes: [.v6]
)
