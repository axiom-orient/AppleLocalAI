#if os(macOS)
  import AppleLocalAIHost
  import AppleLocalAILiteRT
  import AppleLocalAILocalModels
  import CoreAILanguageModels
  import Foundation
  import FoundationModels
  import FoundationModelsUtilities
  import MLXFoundationModels

  /// Host factories for the canonical shared runtime package.
  ///
  /// The macOS package keeps remote Chat Completions and host settings here,
  /// but local Core AI, MLX, and LiteRT construction is delegated to
  /// `AppleLocalAILocalModels`.
  public enum LocalLanguageModels {
    private static let remoteRequestTimeout: TimeInterval = 300

    public static func mlx(
      directory: URL,
      capabilities: [LanguageModelCapabilities.Capability]
    ) throws -> MLXFoundationModels.MLXLanguageModel {
      try AppleLocalAILocalModels.mlx(directory: directory, capabilities: capabilities)
    }

    public static func coreAI(
      directory: URL
    ) async throws -> CoreAILanguageModel {
      let model = try await AppleLocalAILocalModels.coreAI(directory: directory)
      do {
        try Task.checkCancellation()
        return model
      } catch {
        model.unload()
        throw error
      }
    }

    public static func liteRT(
      settings: LiteRTProviderSettings
    ) throws -> LiteRTLanguageModel {
      try AppleLocalAILocalModels.liteRT(configuration: settings.runtimeConfiguration)
    }

    public static func liteRT(
      path: String,
      useCPU: Bool = false
    ) throws -> LiteRTLanguageModel {
      try liteRT(
        settings: .init(modelPath: path, backend: useCPU ? .cpu : .gpu)
      )
    }

    public static func liteRTCapabilities(
      settings: LiteRTProviderSettings
    ) -> LanguageModelCapabilities {
      // This is a non-admitting UI hint. Errors mean no advertised capabilities;
      // the throwing factory remains the only path that admits an actual request.
      // Inspect configuration/metadata only: do not construct an executor or load weights here.
      (try? AppleLocalAILocalModels.liteRTCapabilities(configuration: settings.runtimeConfiguration))
        ?? LanguageModelCapabilities([])
    }

    public static func liteRTCapabilities(path: String) -> LanguageModelCapabilities {
      liteRTCapabilities(settings: .init(modelPath: path, backend: .gpu))
    }

    public static func chatCompletions(
      name: String,
      baseURL: URL,
      headers: [String: String] = [:],
      supportsGuidedGeneration: Bool = false
    ) -> any FoundationModels.LanguageModel {
      let transport = URLSessionConfiguration.ephemeral
      transport.timeoutIntervalForRequest = remoteRequestTimeout
      transport.timeoutIntervalForResource = remoteRequestTimeout
      transport.httpCookieStorage = nil
      transport.urlCredentialStorage = nil
      return ChatCompletionsLanguageModel(
        name: name,
        url: baseURL,
        additionalHeaders: headers,
        supportsGuidedGeneration: supportsGuidedGeneration,
        urlSessionConfiguration: transport
      )
    }

    public static func releaseCoreAIResources(
      _ model: any FoundationModels.LanguageModel
    ) {
      (model as? CoreAILanguageModel)?.unload()
    }

    public static func releaseMLXResources() async {
      await AppleLocalAILocalModels.releaseMLXResources()
    }

    public static func releaseLiteRTResources() async {
      await AppleLocalAILocalModels.releaseLiteRTResources()
    }
  }

  extension LiteRTProviderSettings {
    fileprivate var runtimeConfiguration: LiteRTConfiguration {
      LiteRTConfiguration(
        modelURL: URL(fileURLWithPath: modelPath.trimmingCharacters(in: .whitespacesAndNewlines)),
        backend: backend.externalChoice,
        visionBackend: visionBackend.externalChoice
      )
    }
  }

  extension AppleLocalAILiteRT.LiteRTProviderBackendChoice {
    fileprivate var externalChoice: LiteRTBackendChoice {
      switch self {
      case .cpu: .cpu
      case .gpu: .gpu
      }
    }
  }

  extension AppleLocalAILiteRT.LiteRTProviderVisionBackendChoice {
    fileprivate var externalChoice: LiteRTVisionBackendChoice {
      switch self {
      case .disabled: .disabled
      case .cpu: .cpu
      case .gpu: .gpu
      }
    }
  }

#endif
