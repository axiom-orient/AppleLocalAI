import AppleLocalAICore
import Foundation
import FoundationModels

/// Validated text input. Image data never enters this value.
public struct AppleLocalAITextInput: Equatable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    do {
      self.value = try NormalizedPrompt(value).value
    } catch {
      throw AppleLocalAIError.emptyPrompt
    }
  }
}

/// A file-backed image input. The caller owns any security-scoped access.
public struct AppleLocalAIImageInput: Equatable, Sendable {
  public let url: URL
  public let label: String?

  public init(url: URL, label: String? = nil) throws {
    guard url.isFileURL, !url.path.isEmpty else {
      throw AppleLocalAIError.invalidImageInput
    }
    let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.url = url
    self.label = normalizedLabel?.isEmpty == true ? nil : normalizedLabel
  }
}

/// A text-only request builder. It cannot accidentally carry image state.
public struct AppleLocalAITextRequest: Sendable {
  public let text: AppleLocalAITextInput

  public init(text: AppleLocalAITextInput) {
    self.text = text
  }

  public func makeRequest() -> AppleLocalAIRequest {
    AppleLocalAIRequest(prompt: Prompt(text.value))
  }
}

/// A native Foundation Models vision request. Image data is attached as a
/// native Attachment at this boundary and is never encoded into the text.
public struct AppleLocalAIVisionRequest: Sendable {
  public let text: AppleLocalAITextInput
  public let image: AppleLocalAIImageInput

  public init(text: AppleLocalAITextInput, image: AppleLocalAIImageInput) {
    self.text = text
    self.image = image
  }

  public func makeRequest() throws -> AppleLocalAIRequest {
    try AppleLocalAIRequest(
      text: text.value,
      imageURL: image.url,
      imageLabel: image.label
    )
  }
}

public struct AppleLocalAIRequest: Sendable {
  /// The original Foundation Models prompt. No parallel prompt representation
  /// is introduced by the package.
  public let prompt: Prompt

  /// Validated text convenience.
  public init(text: String) throws {
    do {
      let normalized = try NormalizedPrompt(text)
      self.prompt = Prompt(normalized.value)
    } catch {
      throw AppleLocalAIError.emptyPrompt
    }
  }

  /// Native multimodal convenience for a file-backed image. The caller owns any
  /// security-scoped file access needed by the URL.
  public init(text: String, imageURL: URL, imageLabel: String? = nil) throws {
    let normalized: NormalizedPrompt
    do { normalized = try NormalizedPrompt(text) } catch { throw AppleLocalAIError.emptyPrompt }
    let image = try AppleLocalAIImageInput(url: imageURL, label: imageLabel)

    self.prompt = Prompt {
      normalized.value
      if let label = image.label {
        Attachment(imageURL: image.url).label(label)
      } else {
        Attachment(imageURL: image.url)
      }
    }
  }

  /// Escape hatch for native Foundation Models prompts, including multiple
  /// attachments or custom PromptRepresentable values.
  public init(prompt: Prompt) {
    self.prompt = prompt
  }
}
