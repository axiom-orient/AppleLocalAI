import Foundation

public struct NormalizedPrompt: Equatable, Sendable {
  public let value: String

  public init(_ rawValue: String) throws {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw PromptValidationError.empty }
    self.value = value
  }
}

public enum PromptValidationError: Error, Equatable, Sendable {
  case empty
}
