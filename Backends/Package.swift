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
      exact: "1.0.0"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      exact: "3.32.3"
    ),
    // This stable release includes the iOS Metal thread address-space fixes.
    .package(
      url: "https://github.com/ml-explore/mlx-swift",
      exact: "0.32.3"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers",
      exact: "1.3.4"
    ),
    .package(
      url: "https://github.com/google-ai-edge/LiteRT-LM",
      exact: "0.18.0"
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
      dependencies: ["LeapSDK", "inference_engine"],
      exclude: ["Package.swift", "README.md"]
    ),
    // Keep the native boundary explicit: AppleLocalAILEAP owns the Swift
    // lifecycle and downloads, while this is the only third-party LEAP seam.
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
    .testTarget(
      name: "AppleLocalAILEAPTests",
      dependencies: ["AppleLocalAILEAP", .product(name: "AppleLocalAI", package: "AppleLocalAI")]
    ),
    .testTarget(name: "AppleLocalAILocalModelsTests", dependencies: ["AppleLocalAILocalModels"]),
  ],
  swiftLanguageModes: [.v6]
)
