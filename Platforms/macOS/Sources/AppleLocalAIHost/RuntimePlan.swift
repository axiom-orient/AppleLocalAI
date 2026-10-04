/// Product-level routing policy for local AI on Apple platforms.
///
/// This package does not wrap FoundationModels, Core AI, or MLX. It only fixes
/// the ownership boundary so apps do not grow a second inference framework.
public enum LocalAIRuntime: String, Sendable, Equatable {
  /// Native app feature using Apple's OS-managed on-device model.
  case systemFoundationModel = "system_foundation_model"
  /// Product-owned on-device model distributed and specialized with Core AI.
  case coreAI = "core_ai"
  /// Canonical Mac gateway exposing Foundation Models `LanguageModel` backends to external agents.
  case foundationModelsProvider = "foundation_models_provider"
}

public enum LocalAIPlatform: String, Sendable, Equatable {
  case iPhone
  case mac
}

public enum LocalAIWorkload: String, Sendable, Equatable {
  /// General app intelligence where the system model satisfies product quality.
  case nativeFeature
  /// The product requires its own model weights, behavior, or model version.
  case customProductionModel
  /// A local model must be reachable by Xcode, OpenCode, Codex, CLI, or another process.
  case externalAgent
}

public enum LocalAIPlanError: Error, Sendable, Equatable {
  case externalAgentRequiresMac
}

public struct LocalAIPlan: Sendable, Equatable {
  public let platform: LocalAIPlatform
  public let workload: LocalAIWorkload
  public let runtime: LocalAIRuntime

  public init(platform: LocalAIPlatform, workload: LocalAIWorkload) throws {
    self.platform = platform
    self.workload = workload
    switch workload {
    case .nativeFeature:
      runtime = .systemFoundationModel
    case .customProductionModel:
      runtime = .coreAI
    case .externalAgent:
      guard platform == .mac else { throw LocalAIPlanError.externalAgentRequiresMac }
      runtime = .foundationModelsProvider
    }
  }
}
