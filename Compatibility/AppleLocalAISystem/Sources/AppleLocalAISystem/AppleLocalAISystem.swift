import Foundation
import FoundationModels

/// Creates an Apple system-model session using APIs available on OS 26.
/// Foundation Models owns the returned session's transcript, generation and tools.
public enum AppleLocalAISystem {
  public static func makeSession(
    model: SystemLanguageModel = .default,
    tools: [any Tool] = [],
    instructions: Instructions? = nil
  ) throws -> LanguageModelSession {
    try requireAvailable(model.availability)
    return LanguageModelSession(model: model, tools: tools, instructions: instructions)
  }

  static func requireAvailable(_ availability: SystemLanguageModel.Availability) throws {
    if case .unavailable(let reason) = availability {
      throw AppleLocalAISystemError.unavailable(reason)
    }
  }
}

/// Preserves Apple's exact unavailable reason, including future native cases.
public enum AppleLocalAISystemError: Error, LocalizedError, Equatable, Sendable {
  case unavailable(SystemLanguageModel.Availability.UnavailableReason)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible:
        "This device is not eligible for Apple Intelligence."
      case .appleIntelligenceNotEnabled:
        "Apple Intelligence is not enabled."
      case .modelNotReady:
        "The Apple system language model is not ready."
      @unknown default:
        "The Apple system language model is unavailable (\(String(describing: reason)))."
      }
    }
  }
}
