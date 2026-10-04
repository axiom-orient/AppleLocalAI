#if os(macOS)

  import AppleLocalAIHost
  import AppleLocalAIFoundationModels
  import AppleLocalAILiteRT
  import Foundation
  import FoundationModels

  struct MLXProviderSettings: Codable, Equatable, Sendable {
    /// Local MLX model directory. App inference never routes through HTTP.
    var modelPath: String
    /// MLX guided generation is implemented by the upstream Foundation Models adapter.
    var guidedGeneration: Bool
    /// Tool calling and reasoning are model/template capabilities and must be opted in explicitly.
    var toolCalling: Bool
    var reasoning: Bool

    static let standard = Self(
      modelPath: "",
      guidedGeneration: true,
      toolCalling: false,
      reasoning: false
    )
  }

  struct RemoteProviderSettings: Codable, Equatable, Sendable {
    var baseURL: String
    var modelName: String
    var vision: Bool
    var guidedGeneration: Bool
    var toolCalling: Bool
    var reasoning: Bool

    static let standard = Self(
      baseURL: "", modelName: "", vision: false, guidedGeneration: false,
      toolCalling: false, reasoning: false)
  }

  struct ProviderSettings: Codable, Equatable, Sendable {
    var workload: ModelWorkload
    var allowPrivateCloud: Bool
    var coreAIModelPath: String
    var provider: LocalProviderChoice
    var mlx: MLXProviderSettings
    var liteRT: LiteRTProviderSettings
    var remote: RemoteProviderSettings
    var foundationModels: FoundationModelsSettings

    static let standard = Self(
      provider: .apple,
      mlx: .standard,
      liteRT: .standard,
      remote: .standard,
      foundationModels: .standard,
      workload: .automaticLocal
    )

    private enum CodingKeys: String, CodingKey {
      case workload, allowPrivateCloud, coreAIModelPath
      case provider
      case mlx
      case liteRT
      case remote
      case foundationModels
    }

    init(
      provider: LocalProviderChoice,
      mlx: MLXProviderSettings,
      liteRT: LiteRTProviderSettings,
      remote: RemoteProviderSettings = .standard,
      foundationModels: FoundationModelsSettings = .standard,
      workload: ModelWorkload = .manual,
      allowPrivateCloud: Bool = false,
      coreAIModelPath: String = ""
    ) {
      self.workload = workload
      self.allowPrivateCloud = allowPrivateCloud
      self.coreAIModelPath = coreAIModelPath
      self.provider = provider
      self.mlx = mlx
      self.liteRT = liteRT
      self.remote = remote
      self.foundationModels = foundationModels
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      workload = try container.decodeIfPresent(ModelWorkload.self, forKey: .workload) ?? .manual
      allowPrivateCloud =
        try container.decodeIfPresent(Bool.self, forKey: .allowPrivateCloud) ?? false
      coreAIModelPath = try container.decodeIfPresent(String.self, forKey: .coreAIModelPath) ?? ""
      provider = try container.decode(LocalProviderChoice.self, forKey: .provider)
      mlx = try container.decode(MLXProviderSettings.self, forKey: .mlx)
      liteRT =
        try container.decodeIfPresent(
          LiteRTProviderSettings.self,
          forKey: .liteRT
        ) ?? .standard
      remote =
        try container.decodeIfPresent(
          RemoteProviderSettings.self,
          forKey: .remote
        ) ?? .standard
      foundationModels =
        try container.decodeIfPresent(
          FoundationModelsSettings.self,
          forKey: .foundationModels
        ) ?? .standard
    }
  }

#endif
