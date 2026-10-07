// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "AppleLocalAIMac",
  platforms: [
    .macOS("27.0")
  ],
  products: [
    .library(name: "AppleLocalAIHost", targets: ["AppleLocalAIHost"]),
    .library(name: "AppleLocalAIFoundationModels", targets: ["AppleLocalAIFoundationModels"]),
    .executable(name: "AppleLocalAIProvider", targets: ["AppleLocalAIProvider"]),
    .library(name: "AppleLocalAILiteRT", targets: ["AppleLocalAILiteRT"]),
    .executable(name: "AppleLocalAIMac", targets: ["AppleLocalAIMac"]),
    .executable(name: "AppleLocalAIConsole", targets: ["AppleLocalAIConsole"]),
  ],
  dependencies: [
    .package(name: "AppleLocalAIBackends", path: "../../Backends"),
    .package(
      name: "AppleLocalAI",
      path: "../.."
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      exact: "3.32.3"),
    .package(url: "https://github.com/apple/swift-nio", exact: "2.104.0"),
    .package(
      url: "https://github.com/apple/coreai-models",
      exact: "1.0.0"
    ),
    .package(
      url: "https://github.com/apple/foundation-models-utilities",
      revision: "cc3820def1fe016bc6cd49d958cd2f2a29be76a8"
    ),
  ],
  targets: [
    .target(
      name: "AppleLocalAIHost",
      dependencies: [
        .product(name: "AppleLocalAICore", package: "AppleLocalAI")
      ],
      path: "Sources/AppleLocalAIHost"
    ),
    .target(name: "AppleLocalAIWire", dependencies: ["AppleLocalAIHost"]),
    .target(
      name: "AppleLocalAIFoundationModels",
      dependencies: [
        "AppleLocalAIHost", "AppleLocalAILiteRT",
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(name: "AppleLocalAICore", package: "AppleLocalAI"),
        .product(name: "AppleLocalAILocalModels", package: "AppleLocalAIBackends"),
        .product(name: "CoreAILM", package: "coreai-models"),
        .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities"),
        .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
      ]),
    .executableTarget(
      name: "AppleLocalAIProvider",
      dependencies: [
        "AppleLocalAIHost", "AppleLocalAIWire", "AppleLocalAIFoundationModels",
        "AppleLocalAILiteRT",
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(name: "AppleLocalAICore", package: "AppleLocalAI"),
        .product(name: "AppleLocalAILocalModels", package: "AppleLocalAIBackends"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ]),
    .testTarget(
      name: "AppleLocalAIProviderTests",
      dependencies: [
        "AppleLocalAIProvider", "AppleLocalAIWire", "AppleLocalAIFoundationModels",
        "AppleLocalAIHost",
      ]),
    .testTarget(name: "AppleLocalAILiteRTTests", dependencies: ["AppleLocalAILiteRT"]),
    .testTarget(name: "AppleLocalAIWireTests", dependencies: ["AppleLocalAIWire"]),
    .target(
      name: "AppleLocalAILiteRT",
      dependencies: []
    ),
    .executableTarget(
      name: "AppleLocalAIMac",
      dependencies: [
        "AppleLocalAIHost",
        "AppleLocalAIFoundationModels",
        "AppleLocalAILiteRT",
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(name: "AppleLocalAICore", package: "AppleLocalAI"),
        .product(name: "AppleLocalAILocalModels", package: "AppleLocalAIBackends"),
        .product(name: "CoreAILM", package: "coreai-models"),
        .product(
          name: "FoundationModelsUtilities",
          package: "foundation-models-utilities"
        ),
      ]
    ),
    .executableTarget(
      name: "AppleLocalAIConsole",
      dependencies: [
        "AppleLocalAIHost",
        "AppleLocalAIFoundationModels",
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(name: "AppleLocalAICore", package: "AppleLocalAI"),
        .product(
          name: "FoundationModelsUtilities",
          package: "foundation-models-utilities"
        ),
      ]
    ),
    .testTarget(
      name: "AppleLocalAIMacTests",
      dependencies: [
        "AppleLocalAIMac", "AppleLocalAIHost", "AppleLocalAILiteRT", "AppleLocalAIFoundationModels",
        "AppleLocalAIWire",
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(name: "AppleLocalAILocalModels", package: "AppleLocalAIBackends"),
      ]
    ),
    .testTarget(
      name: "AppleLocalAIEvaluationTests",
      dependencies: [
        "AppleLocalAIHost", "AppleLocalAIMac", "AppleLocalAIFoundationModels",
        .product(name: "AppleLocalAI", package: "AppleLocalAI"),
        .product(name: "CoreAILM", package: "coreai-models"),
      ]
    ),
    .testTarget(
      name: "AppleLocalAIHostTests",
      dependencies: [
        "AppleLocalAIHost", "AppleLocalAIFoundationModels",
        .product(name: "AppleLocalAICore", package: "AppleLocalAI"),
        .product(name: "AppleLocalAILocalModels", package: "AppleLocalAIBackends"),
      ],
      path: "Tests/AppleLocalAITests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
