import Foundation
import FoundationModels

struct LEAPTranscriptMessage: Sendable, Equatable {
  enum Role: Sendable, Equatable {
    case system
    case user
    case assistant
  }

  let role: Role
  let content: String
}

struct LEAPTranscriptPlan: Sendable, Equatable {
  static let defaultMaximumTokens: Int32 = 768
  static let maximumSupportedTokens: Int = 4_096
  static let maximumTranscriptEntries = 4_096
  static let maximumPromptBytes = 64 * 1_024
  static let maximumOutputBytes = 128 * 1_024

  let messages: [LEAPTranscriptMessage]
  let userMessage: String
  let schemaJSON: String?
  let maximumTokens: Int32
  let maximumOutputBytes: Int

  static func make(
    from request: LanguageModelExecutorGenerationRequest
  ) throws -> Self {
    try validateGenerationOptions(request)
    guard request.transcript.count <= maximumTranscriptEntries else {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "The LEAP transcript cannot contain more than "
          + String(maximumTranscriptEntries) + " entries.")
    }

    guard request.enabledToolDefinitions.isEmpty else {
      throw LanguageModelError.unsupportedCapability(
        .init(
          capability: .toolCalling,
          debugDescription: "LEAP text generation does not provide Foundation Models tool calling."
        ))
    }

    var messages: [LEAPTranscriptMessage] = []
    messages.reserveCapacity(request.transcript.count)
    var instructionsClosed = false
    for entry in request.transcript {
      switch entry {
      case .instructions(let instructions):
        guard !instructionsClosed else {
          throw unsupportedTranscript(
            entry,
            "LEAP instructions must remain before the conversation history.")
        }
        guard instructions.toolDefinitions.isEmpty else {
          throw LanguageModelError.unsupportedCapability(
            .init(
              capability: .toolCalling,
              debugDescription:
                "LEAP text generation does not provide Foundation Models tool calling."
            ))
        }
        let content = try text(of: instructions.segments, entry: entry)
        if !content.isEmpty {
          messages.append(.init(role: .system, content: content))
        }
      case .prompt(let prompt):
        instructionsClosed = true
        messages.append(
          .init(
            role: .user,
            content: try text(of: prompt.segments, entry: entry)))
      case .response(let response):
        instructionsClosed = true
        messages.append(
          .init(
            role: .assistant,
            content: try text(of: response.segments, entry: entry)))
      case .reasoning:
        // Reasoning is provider metadata and is intentionally not replayed as
        // user-visible model text.
        continue
      case .toolCalls, .toolOutput:
        instructionsClosed = true
        throw unsupportedTranscript(
          entry,
          "LEAP text generation does not accept tool transcript entries.")
      @unknown default:
        throw unsupportedTranscript(
          entry,
          "The transcript contains an unsupported Foundation Models entry.")
      }
    }

    guard let last = messages.last, last.role == .user,
      !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw AppleLocalAILEAPError.noPrompt
    }

    var promptBytes = 0
    for message in messages {
      let (next, overflow) = promptBytes.addingReportingOverflow(message.content.utf8.count)
      guard !overflow, next <= maximumPromptBytes else {
        throw AppleLocalAILEAPError.invalidGenerationOptions(
          "The LEAP prompt history cannot exceed \(maximumPromptBytes) UTF-8 bytes.")
      }
      promptBytes = next
    }

    let maximumTokens = try maximumTokens(for: request.generationOptions)
    let schema = try schemaJSON(for: request.schema)
    let (combinedBytes, combinedOverflow) = promptBytes.addingReportingOverflow(
      schema?.utf8.count ?? 0)
    guard !combinedOverflow, combinedBytes <= maximumPromptBytes else {
      throw AppleLocalAILEAPError.invalidSchema
    }
    return Self(
      messages: Array(messages.dropLast()),
      userMessage: last.content,
      schemaJSON: schema,
      maximumTokens: maximumTokens,
      // Token size varies by language and vocabulary. Enforce the independent
      // byte ceiling without treating four UTF-8 bytes as a token limit.
      maximumOutputBytes: maximumOutputBytes)
  }

  private static func validateGenerationOptions(
    _ request: LanguageModelExecutorGenerationRequest
  ) throws {
    if request.generationOptions.temperature != nil
      || request.generationOptions.samplingMode != nil
    {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "LEAP owns its native sampling policy; temperature and sampling mode are unsupported by this adapter."
      )
    }
    if request.contextOptions.reasoningLevel != nil {
      throw LanguageModelError.unsupportedCapability(
        .init(
          capability: .reasoning,
          debugDescription: "The selected LEAP text model does not expose reasoning output."
        ))
    }
  }

  private static func maximumTokens(for options: GenerationOptions) throws -> Int32 {
    let requested = options.maximumResponseTokens ?? Int(defaultMaximumTokens)
    guard (1...maximumSupportedTokens).contains(requested) else {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "maximumResponseTokens must be between 1 and \(maximumSupportedTokens) for LEAP.")
    }
    guard requested <= Int(Int32.max) else {
      throw AppleLocalAILEAPError.invalidGenerationOptions(
        "maximumResponseTokens is outside LEAP's native Int32 range.")
    }
    return Int32(requested)
  }

  private static func schemaJSON(for schema: GenerationSchema?) throws -> String? {
    guard let schema else { return nil }
    do {
      let encoded = try JSONEncoder().encode(schema)
      let object = try JSONSerialization.jsonObject(with: encoded, options: [])
      guard object is [String: Any] else { throw AppleLocalAILEAPError.invalidSchema }
      let canonical = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys])
      guard let string = String(data: canonical, encoding: .utf8), !string.isEmpty else {
        throw AppleLocalAILEAPError.invalidSchema
      }
      return string
    } catch let error as AppleLocalAILEAPError {
      throw error
    } catch {
      throw AppleLocalAILEAPError.invalidSchema
    }
  }

  private static func text(
    of segments: [Transcript.Segment],
    entry: Transcript.Entry
  ) throws -> String {
    try segments.map { segment in
      switch (segment, entry) {
      case (.text(let value), _):
        return value.content
      case (.structure(let value), .response):
        // Foundation Models commits guided responses as structured segments.
        // Replay that response as JSON so the next turn can use its history.
        return value.content.jsonString
      default:
        throw unsupportedTranscript(
          entry,
          "LEAP accepts text input and text or structured response history only.")
      }
    }.joined(separator: " ")
  }

  private static func unsupportedTranscript(
    _ entry: Transcript.Entry,
    _ message: String
  ) -> LanguageModelError {
    .unsupportedTranscriptContent(
      .init(unsupportedContent: [entry], debugDescription: message))
  }
}
