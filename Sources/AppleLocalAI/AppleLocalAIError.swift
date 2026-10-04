import Foundation

public enum AppleLocalAIError: Error, LocalizedError, Sendable {
  case emptyPrompt
  case invalidImageInput
  case operationInProgress
  case invalidMaximumResponseTokens
  case invalidTemperature
  case invalidHistoryLimit
  case requiredToolCallingWithoutTools
  case profileUnavailable
  case tokenCountUnavailable
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .emptyPrompt:
      "Prompt must contain non-whitespace text."
    case .invalidImageInput:
      "Image input must be a non-empty file URL."
    case .operationInProgress:
      "A model operation is already running or settling cancellation."
    case .invalidMaximumResponseTokens:
      "maximumResponseTokens must be greater than zero when supplied."
    case .invalidTemperature:
      "temperature must be finite and within 0...1."
    case .invalidHistoryLimit:
      "History limit must be greater than zero."
    case .requiredToolCallingWithoutTools:
      "Required tool calling needs at least one tool."
    case .profileUnavailable:
      "The session has no active model profile."
    case .tokenCountUnavailable:
      "Token counting is only exposed by the active SystemLanguageModel on iOS 27."
    case .cancelled:
      "The model operation was cancelled."
    }
  }
}
