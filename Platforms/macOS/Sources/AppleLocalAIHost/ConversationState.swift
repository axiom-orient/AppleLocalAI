import AppleLocalAICore
import Foundation

public struct ConversationImage: Equatable, Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public var fileName: String {
    let name = url.lastPathComponent
    return name.isEmpty ? "이미지" : name
  }
}

/// A submitted turn. Its failable initializer prevents an empty prompt from
/// becoming a valid domain value.
public struct ConversationTurn: Equatable, Sendable {
  public let prompt: String
  public let image: ConversationImage?

  public init?(prompt: String, image: ConversationImage?) {
    guard let normalizedPrompt = try? NormalizedPrompt(prompt).value else { return nil }
    self.prompt = normalizedPrompt
    self.image = image
  }
}

/// UI-visible conversation state. Foundation Models' session and transcript
/// are intentionally not part of this value; the framework owns them.
public enum ConversationState: Equatable, Sendable {
  case empty
  case responding(turn: ConversationTurn, answer: String)
  case cancelling(turn: ConversationTurn, answer: String)
  case answered(turn: ConversationTurn, answer: String)
  case failedBeforeStart(message: String)
  case failed(turn: ConversationTurn, message: String)
  case cancelled(turn: ConversationTurn)

  public enum Event: Equatable, Sendable {
    case reset
    case begin(prompt: String, image: ConversationImage?)
    case updateAnswer(String)
    case finish(answer: String)
    case fail(message: String)
    case failBeforeStart(message: String)
    case failWithInput(prompt: String, image: ConversationImage?, message: String)
    case requestCancellation
    case settleCancellation
  }

  public enum TransitionError: Error, Equatable, Sendable {
    case emptyPrompt
    case emptyAnswer
    case emptyFailureMessage
    case responseAlreadyActive
    case responseNotActive
    case cancellationNotActive
  }

  /// Pure state transition. No Foundation Models or I/O values cross this
  /// boundary; callers decide how to handle a rejected event.
  public func applying(_ event: Event) -> Result<Self, TransitionError> {
    switch event {
    case .reset:
      return .success(.empty)

    case .begin(let prompt, let image):
      guard !isBusy else { return .failure(.responseAlreadyActive) }
      guard let turn = ConversationTurn(prompt: prompt, image: image) else {
        return .failure(.emptyPrompt)
      }
      return .success(.responding(turn: turn, answer: ""))

    case .updateAnswer(let answer):
      guard case .responding(let turn, _) = self else {
        return .failure(.responseNotActive)
      }
      return .success(.responding(turn: turn, answer: answer))

    case .finish(let answer):
      guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(.emptyAnswer)
      }
      guard case .responding(let turn, _) = self else {
        return .failure(.responseNotActive)
      }
      return .success(.answered(turn: turn, answer: answer))

    case .fail(let message):
      guard let message = Self.normalizedMessage(message) else {
        return .failure(.emptyFailureMessage)
      }
      guard case .responding(let turn, _) = self else {
        return .failure(.responseNotActive)
      }
      return .success(.failed(turn: turn, message: message))

    case .failBeforeStart(let message):
      guard !isBusy else { return .failure(.responseAlreadyActive) }
      guard let message = Self.normalizedMessage(message) else {
        return .failure(.emptyFailureMessage)
      }
      return .success(.failedBeforeStart(message: message))

    case .failWithInput(let prompt, let image, let message):
      guard !isBusy else { return .failure(.responseAlreadyActive) }
      guard let turn = ConversationTurn(prompt: prompt, image: image) else {
        return .failure(.emptyPrompt)
      }
      guard let message = Self.normalizedMessage(message) else {
        return .failure(.emptyFailureMessage)
      }
      return .success(.failed(turn: turn, message: message))

    case .requestCancellation:
      guard case .responding(let turn, let answer) = self else {
        return .failure(.responseNotActive)
      }
      return .success(.cancelling(turn: turn, answer: answer))

    case .settleCancellation:
      guard case .cancelling(let turn, _) = self else {
        return .failure(.cancellationNotActive)
      }
      return .success(.cancelled(turn: turn))
    }
  }

  public var submittedTurn: ConversationTurn? {
    switch self {
    case .empty, .failedBeforeStart:
      return nil
    case .responding(let turn, _), .cancelling(let turn, _), .answered(let turn, _),
      .failed(let turn, _), .cancelled(let turn):
      return turn
    }
  }

  public var answer: String {
    guard case .answered(_, let answer) = self else { return "" }
    return answer
  }

  public var responseText: String {
    switch self {
    case .responding(_, let answer), .cancelling(_, let answer), .answered(_, let answer):
      return answer
    case .empty, .failedBeforeStart, .failed, .cancelled:
      return ""
    }
  }

  public var errorMessage: String? {
    switch self {
    case .failedBeforeStart(let message), .failed(_, let message):
      return message
    case .empty, .responding, .cancelling, .answered, .cancelled:
      return nil
    }
  }

  public var isResponding: Bool {
    if case .responding = self { return true }
    return false
  }

  public var isCancelling: Bool {
    if case .cancelling = self { return true }
    return false
  }

  public var isBusy: Bool {
    isResponding || isCancelling
  }

  public var wasCancelled: Bool {
    if case .cancelled = self { return true }
    return false
  }

  private static func normalizedMessage(_ message: String) -> String? {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}
