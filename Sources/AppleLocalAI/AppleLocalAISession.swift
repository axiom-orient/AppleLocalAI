import AppleLocalAICore
import Foundation
import FoundationModels

@MainActor
public final class AppleLocalAISession {
  public enum Phase: Equatable, Sendable {
    case idle
    case running
    case cancelling
  }

  private var nativeSession: LanguageModelSession
  private let operation = SessionOperation()

  public init(
    profile: AppleLocalAIProfile,
    history: [Transcript.Entry] = []
  ) {
    let session = LanguageModelSession(
      profile: AppleLocalAIRootProfile(),
      history: history
    )
    session.properties.appleLocalAIProfile = profile
    self.nativeSession = session
  }

  public var phase: Phase {
    switch operation.lifecycle {
    case .idle: nativeSession.isResponding ? .running : .idle
    case .running: .running
    case .cancelling: .cancelling
    }
  }

  public var transcript: Transcript { nativeSession.transcript }
  public var history: [Transcript.Entry] { Array(nativeSession.transcript.history) }
  public var usage: LanguageModelSession.Usage { nativeSession.usage }
  /// The model currently installed in the native session's dynamic profile.
  public var activeModel: (any LanguageModel)? {
    nativeSession.properties.appleLocalAIProfile?.model
  }
  public var modelCapabilities: AppleLocalAIModelCapabilities? {
    activeModel.map { AppleLocalAIModelCapabilities($0.capabilities) }
  }
  public var isBusy: Bool { operation.isBusy || nativeSession.isResponding }

  /// Changes the active dynamic profile without creating another transcript owner.
  public func reconfigure(_ profile: AppleLocalAIProfile) throws {
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    nativeSession.properties.appleLocalAIProfile = profile
  }

  /// Removes the active model profile without discarding the native transcript.
  /// Callers use this at an idle resource-release boundary before unloading a
  /// model instance owned outside this package.
  public func clearProfile() throws {
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    nativeSession.properties.appleLocalAIProfile = nil
  }

  /// Explicitly starts a new conversation. This is the only API that replaces the
  /// native session and therefore discards the old transcript authority.
  public func reset(
    profile: AppleLocalAIProfile,
    history: [Transcript.Entry] = []
  ) throws {
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    let session = LanguageModelSession(
      profile: AppleLocalAIRootProfile(),
      history: history
    )
    session.properties.appleLocalAIProfile = profile
    nativeSession = session
  }

  public func feedbackAttachment(
    sentiment: LanguageModelFeedback.Sentiment? = nil,
    issues: [LanguageModelFeedback.Issue] = [],
    desiredResponseText: String? = nil
  ) throws -> Data {
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    return nativeSession.logFeedbackAttachment(
      sentiment: sentiment,
      issues: issues,
      desiredResponseText: desiredResponseText
    )
  }

  public func prewarm(promptPrefix: Prompt? = nil) throws {
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    nativeSession.prewarm(promptPrefix: promptPrefix)
  }

  public func cancel() {
    operation.cancel()
  }

  public func respond(
    _ request: AppleLocalAIRequest,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) async throws -> LanguageModelSession.Response<String> {
    try await runNative {
      try await self.nativeSession.respond(
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
    }
  }

  public func stream(
    _ request: AppleLocalAIRequest,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: [String: any ConvertibleToGeneratedContent] = [:],
    onSnapshot: @escaping @MainActor (AppleLocalAITextSnapshot) -> Void
  ) async throws -> AppleLocalAITextSnapshot {
    try await consumeStream(
      makeStream: {
        self.nativeSession.streamResponse(
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        ) {
          request.prompt
        }
      },
      transform: Self.textSnapshot,
      onSnapshot: { onSnapshot($0) }
    )
  }

  /// Async callback variant for hosts that must forward each native snapshot
  /// across an I/O boundary, such as the macOS provider's HTTP stream.
  public func streamAsync(
    _ request: AppleLocalAIRequest,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: [String: any ConvertibleToGeneratedContent] = [:],
    onSnapshot: @escaping @MainActor (AppleLocalAITextSnapshot) async throws -> Void
  ) async throws -> AppleLocalAITextSnapshot {
    try await consumeStream(
      makeStream: {
        self.nativeSession.streamResponse(
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        ) {
          request.prompt
        }
      },
      transform: Self.textSnapshot,
      onSnapshot: onSnapshot
    )
  }

  /// Streams native dynamic-schema output while preserving Foundation Models'
  /// generated content and the canonical transcript.
  public func stream(
    _ request: AppleLocalAIRequest,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:],
    onSnapshot: @escaping @MainActor (AppleLocalAISchemaSnapshot) -> Void
  ) async throws -> AppleLocalAISchemaSnapshot {
    try await consumeStream(
      makeStream: {
        self.nativeSession.streamResponse(
          to: request.prompt,
          schema: schema,
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        )
      },
      transform: { snapshot in
        AppleLocalAISchemaSnapshot(
          content: snapshot.rawContent,
          usage: snapshot.usage,
          transcriptEntries: Array(snapshot.transcriptEntries)
        )
      },
      onSnapshot: { onSnapshot($0) }
    )
  }

  /// Streams native structured output while preserving Foundation Models'
  /// partial-generation type and raw generated content.
  public func streamGenerated<Content: Generable & Sendable>(
    _ request: AppleLocalAIRequest,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:],
    onSnapshot: @escaping @MainActor (AppleLocalAIGeneratedSnapshot<Content>) -> Void
  ) async throws -> AppleLocalAIGeneratedSnapshot<Content>
  where Content.PartiallyGenerated: Sendable {
    try await consumeStream(
      makeStream: {
        self.nativeSession.streamResponse(
          generating: type,
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        ) {
          request.prompt
        }
      },
      transform: { snapshot in
        AppleLocalAIGeneratedSnapshot<Content>(
          content: snapshot.content,
          rawContent: snapshot.rawContent,
          usage: snapshot.usage,
          transcriptEntries: Array(snapshot.transcriptEntries)
        )
      },
      onSnapshot: { onSnapshot($0) }
    )
  }

  public func generate<Content: Generable & Sendable>(
    _ request: AppleLocalAIRequest,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) async throws -> LanguageModelSession.Response<Content> {
    try await runNative {
      try await self.nativeSession.respond(
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
    }
  }

  public func generate(
    _ request: AppleLocalAIRequest,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: [String: any ConvertibleToGeneratedContent] = [:]
  ) async throws -> LanguageModelSession.Response<GeneratedContent> {
    try await runNative {
      try await self.nativeSession.respond(
        schema: schema,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      ) {
        request.prompt
      }
    }
  }

  /// Counts prompt tokens using Apple's OS 27 `SystemLanguageModel` API.
  /// Local model conformers and Private Cloud Compute do not expose an
  /// equivalent token-counting API in the OS 27 SDK, so this method reports a
  /// typed unavailability error for those active models.
  public func tokenCount(for request: AppleLocalAIRequest) async throws -> Int {
    try await tokenCount(for: request.prompt)
  }

  public func tokenCount(for prompt: Prompt) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: prompt)
  }

  public func tokenCount(for instructions: Instructions) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: instructions)
  }

  public func tokenCount(for tools: [any Tool]) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: tools)
  }

  public func tokenCount(for schema: GenerationSchema) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: schema)
  }

  public func tokenCount(for transcriptEntries: [Transcript.Entry]) async throws -> Int {
    let model = try systemModelForTokenCounting()
    return try await model.tokenCount(for: transcriptEntries)
  }

  private static func textSnapshot(
    _ snapshot: LanguageModelSession.ResponseStream<String>.Snapshot
  ) -> AppleLocalAITextSnapshot {
    AppleLocalAITextSnapshot(
      text: snapshot.content,
      rawContent: snapshot.rawContent,
      usage: snapshot.usage,
      transcriptEntries: Array(snapshot.transcriptEntries)
    )
  }

  /// One delivery policy for every native response type. After cancellation or
  /// consumer failure, drain the native stream before releasing admission.
  private func consumeStream<Content: Generable, Snapshot: Sendable>(
    makeStream: @escaping @MainActor () -> LanguageModelSession.ResponseStream<Content>,
    transform:
      @escaping @MainActor (LanguageModelSession.ResponseStream<Content>.Snapshot) -> Snapshot,
    onSnapshot: @escaping @MainActor (Snapshot) async throws -> Void
  ) async throws -> Snapshot {
    var deliveryError: (any Error)?
    do {
      return try await runNative {
        var latest: Snapshot?
        for try await snapshot in makeStream() {
          // Do not publish buffered snapshots after cancellation or I/O failure.
          guard deliveryError == nil, !Task.isCancelled else { continue }
          let value = transform(snapshot)
          latest = value
          do {
            try await onSnapshot(value)
          } catch {
            deliveryError = error
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
        try Task.checkCancellation()
        guard let latest else { throw AppleLocalAIStreamError.emptyStream }
        return latest
      }
    } catch {
      // Native teardown or cancellation normalization must not replace the
      // original consumer error, even when that error requests cancellation.
      throw deliveryError ?? error
    }
  }

  private func systemModelForTokenCounting() throws -> SystemLanguageModel {
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    guard let model = activeModel as? SystemLanguageModel else {
      throw AppleLocalAIError.tokenCountUnavailable
    }
    return model
  }

  private func runNative<Value: Sendable>(
    _ effect: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    guard !Task.isCancelled else { throw AppleLocalAIError.cancelled }
    guard !isBusy else { throw AppleLocalAIError.operationInProgress }
    let session = nativeSession
    return try await operation.run(
      settleEffect: {
        while session.isResponding {
          try await Task.sleep(for: .milliseconds(10))
        }
      }, effect)
  }
}

public struct AppleLocalAITextSnapshot: Sendable {
  public let text: String
  public let rawContent: GeneratedContent
  public let usage: LanguageModelSession.Usage
  public let transcriptEntries: [Transcript.Entry]

  public var transcriptEntryCount: Int { transcriptEntries.count }
}

public struct AppleLocalAIGeneratedSnapshot<Content: Generable & Sendable>: Sendable
where Content.PartiallyGenerated: Sendable {
  public let content: Content.PartiallyGenerated
  public let rawContent: GeneratedContent
  public let usage: LanguageModelSession.Usage
  public let transcriptEntries: [Transcript.Entry]

  public var transcriptEntryCount: Int { transcriptEntries.count }
}

public struct AppleLocalAISchemaSnapshot: Sendable {
  public let content: GeneratedContent
  public let usage: LanguageModelSession.Usage
  public let transcriptEntries: [Transcript.Entry]

  public var transcriptEntryCount: Int { transcriptEntries.count }
}

public enum AppleLocalAIStreamError: Error, Sendable {
  case emptyStream
}
