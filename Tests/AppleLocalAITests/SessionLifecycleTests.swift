import FoundationModels
import Testing

@testable import AppleLocalAI

@Suite("Session lifecycle")
@MainActor
struct SessionLifecycleTests {
  @Test("Cancelling a native response keeps all session mutation guards active until settlement")
  func explicitCancellationWaitsForNativeSettlement() async throws {
    let effect = SuspendedResponse()
    let profile = try AppleLocalAIProfile(model: SuspendedResponseModel(effect: effect))
    let session = AppleLocalAISession(profile: profile)
    session.cancel()
    #expect(session.phase == .idle)

    let operation = Task { try await session.respond(AppleLocalAIRequest(text: "Hello")) }
    await effect.waitUntilStarted()
    #expect(session.phase == .running)

    session.cancel()
    session.cancel()
    #expect(session.phase == .cancelling)
    #expect(session.isBusy)
    #expect(throws: AppleLocalAIError.operationInProgress) { try session.reconfigure(profile) }
    #expect(throws: AppleLocalAIError.operationInProgress) { try session.reset(profile: profile) }
    #expect(throws: AppleLocalAIError.operationInProgress) { try session.clearProfile() }
    await #expect(throws: AppleLocalAIError.operationInProgress) {
      try await session.respond(AppleLocalAIRequest(text: "Replacement"))
    }

    effect.release()
    await #expect(throws: AppleLocalAIError.cancelled) { try await operation.value }
    #expect(effect.observedCancellation)
    #expect(session.phase == .idle)
    #expect(!session.isBusy)
    try session.reconfigure(AppleLocalAIProfile(model: FixedResponseModel("next")))
    #expect(try await session.respond(AppleLocalAIRequest(text: "Next")).content == "next")
    session.cancel()
    #expect(session.phase == .idle)
  }

  @Test("A running native response rejects concurrent calls and profile mutation")
  func busyGuardsPreserveNativeOperation() async throws {
    let effect = SuspendedResponse()
    let profile = try AppleLocalAIProfile(model: SuspendedResponseModel(effect: effect))
    let session = AppleLocalAISession(profile: profile)
    let operation = Task { try await session.respond(AppleLocalAIRequest(text: "Hello")) }
    await effect.waitUntilStarted()

    await #expect(throws: AppleLocalAIError.operationInProgress) {
      try await session.respond(AppleLocalAIRequest(text: "Replacement"))
    }
    #expect(throws: AppleLocalAIError.operationInProgress) { try session.reconfigure(profile) }
    #expect(throws: AppleLocalAIError.operationInProgress) { try session.reset(profile: profile) }
    #expect(throws: AppleLocalAIError.operationInProgress) { try session.clearProfile() }
    #expect(session.phase == .running)

    effect.release()
    #expect(try await operation.value.content == "settled")
    #expect(!effect.observedCancellation)
    #expect(session.phase == .idle)
  }

  @Test(
    "Cancelling from a snapshot suppresses further delivery for every stream API",
    arguments: StreamKind.allCases)
  private func cancelledSnapshotDelivery(kind: StreamKind) async throws {
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: FixedResponseModel(#"{"answer":"ready"}"#)))
    let request = try AppleLocalAIRequest(text: "Hello")
    var delivered = 0
    let cancelDelivery = {
      delivered += 1
      session.cancel()
    }

    await #expect(throws: AppleLocalAIError.cancelled) {
      switch kind {
      case .text:
        _ = try await session.stream(request) { _ in cancelDelivery() }
      case .asyncText:
        _ = try await session.streamAsync(request) { _ in cancelDelivery() }
      case .generated:
        _ = try await session.streamGenerated(request, generating: StreamAnswer.self) { _ in
          cancelDelivery()
        }
      case .schema:
        _ = try await session.stream(request, schema: StreamAnswer.generationSchema) { _ in
          cancelDelivery()
        }
      }
    }
    #expect(delivered == 1)
    #expect(session.phase == .idle)
  }

  @Test("Async snapshot I/O failure is preserved after native stream teardown")
  func snapshotFailureIsNotHiddenAsCancellation() async throws {
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: FixedResponseModel("answer")))
    var delivered = 0
    await #expect(throws: EffectError.failed) {
      try await session.streamAsync(AppleLocalAIRequest(text: "Hello")) { _ in
        delivered += 1
        throw EffectError.failed
      }
    }
    #expect(delivered == 1)
    #expect(session.phase == .idle)
    let next = try await session.respond(AppleLocalAIRequest(text: "Next"))
    #expect(next.content == "answer")
  }

  @Test(
    "Every stream API returns its final native content, usage and transcript",
    arguments: StreamKind.allCases)
  private func finalSnapshotPreservesNativeState(kind: StreamKind) async throws {
    let payload = #"{"answer":"ready"}"#
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: FixedResponseModel(payload)))
    let request = try AppleLocalAIRequest(text: "Hello")
    var lastRawContent: String?
    let rawContent: GeneratedContent
    let usage: LanguageModelSession.Usage
    let entries: [Transcript.Entry]

    switch kind {
    case .text:
      let result = try await session.stream(request) { lastRawContent = $0.rawContent.jsonString }
      #expect(result.text == payload)
      rawContent = result.rawContent
      usage = result.usage
      entries = result.transcriptEntries
    case .asyncText:
      let result = try await session.streamAsync(request) {
        lastRawContent = $0.rawContent.jsonString
      }
      #expect(result.text == payload)
      rawContent = result.rawContent
      usage = result.usage
      entries = result.transcriptEntries
    case .generated:
      let result = try await session.streamGenerated(request, generating: StreamAnswer.self) {
        lastRawContent = $0.rawContent.jsonString
      }
      #expect(result.content.answer == "ready")
      rawContent = result.rawContent
      usage = result.usage
      entries = result.transcriptEntries
    case .schema:
      let result = try await session.stream(request, schema: StreamAnswer.generationSchema) {
        lastRawContent = $0.content.jsonString
      }
      #expect(try result.content.value(String.self, forProperty: "answer") == "ready")
      rawContent = result.content
      usage = result.usage
      entries = result.transcriptEntries
    }

    #expect(lastRawContent == rawContent.jsonString)
    #expect(usage.output.totalTokenCount == 1)
    #expect(usage.output.totalTokenCount == session.usage.output.totalTokenCount)
    #expect(entries == Array(session.history.suffix(entries.count)))
    #expect(!entries.isEmpty)
    #expect(session.phase == .idle)
  }

  @Test("Consumer failure wins over explicit session cancellation during delivery")
  func consumerFailureWinsOverSessionCancellation() async throws {
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(
        model: FixedResponseModel("partial")
      ))
    var delivered = 0

    await #expect(throws: EffectError.failed) {
      try await session.streamAsync(AppleLocalAIRequest(text: "Hello")) { _ in
        delivered += 1
        session.cancel()
        throw EffectError.failed
      }
    }

    #expect(delivered == 1)
    #expect(session.phase == .idle)
    try session.reconfigure(AppleLocalAIProfile(model: FixedResponseModel("recovered")))
    #expect(try await session.respond(AppleLocalAIRequest(text: "Next")).content == "recovered")
  }

  @Test("A consumer CancellationError retains its original type")
  func consumerCancellationIsNotNormalized() async throws {
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: FixedResponseModel("answer")))

    await #expect(throws: CancellationError.self) {
      try await session.streamAsync(AppleLocalAIRequest(text: "Hello")) { _ in
        throw CancellationError()
      }
    }
    #expect(session.phase == .idle)
  }

  @Test("A native stream failure remains visible without a consumer failure")
  func nativeStreamFailureIsNotHidden() async throws {
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(
        model: FixedResponseModel("partial", failsAfterResponse: true)))

    await #expect(throws: EffectError.nativeFailure) {
      try await session.streamAsync(AppleLocalAIRequest(text: "Hello")) { _ in }
    }
    #expect(session.phase == .idle)
  }

  @Test("Native session responses preserve history across profile changes")
  func nativeSessionOwnsHistory() async throws {
    // The executor is a deterministic fixture. This verifies the native session
    // integration and transcript ownership, not actual model inference.
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: FixedResponseModel("first")))
    let first = try await session.respond(AppleLocalAIRequest(text: "Hello"))
    #expect(first.content == "first")
    #expect(session.phase == .idle)
    let firstHistory = session.history
    #expect(!firstHistory.isEmpty)

    let nextProfile = try AppleLocalAIProfile(model: FixedResponseModel("second"))
    try session.reconfigure(nextProfile)
    #expect(session.history == firstHistory)
    let second = try await session.respond(AppleLocalAIRequest(text: "Continue"))
    #expect(second.content == "second")
    #expect(Array(session.history.prefix(firstHistory.count)) == firstHistory)
    #expect(session.history.count > firstHistory.count)

    let completedHistory = session.history
    try session.clearProfile()
    #expect(session.history == completedHistory)
    await #expect(throws: AppleLocalAIError.profileUnavailable) {
      _ = try await session.respond(AppleLocalAIRequest(text: "No active model"))
    }
    #expect(session.phase == .idle)
    #expect(Array(session.history.prefix(completedHistory.count)) == completedHistory)
    try session.reset(profile: nextProfile)
    #expect(session.history.isEmpty)
  }

  @Test("Dynamic profile forwards generation policy to the native executor")
  func dynamicProfileForwardsGenerationPolicy() async throws {
    let profile = try AppleLocalAIProfile(
      model: GenerationPolicyProbeModel(
        expectedTemperature: 0.25,
        expectedMaximumResponseTokens: 42,
        expectsLightReasoning: true),
      temperature: 0.25,
      samplingMode: .greedy,
      maximumResponseTokens: 42,
      reasoningLevel: .light,
      toolCallingMode: .allowed
    )
    let session = AppleLocalAISession(profile: profile)

    let response = try await session.respond(AppleLocalAIRequest(text: "Check policy"))

    #expect(response.content == "policy-forwarded")
  }

  @Test("A failed native tool preflight prevents tool execution")
  func toolCallPreflightStopsDispatch() async throws {
    let preflightCalls = CallCounter()
    let toolCalls = CallCounter()
    let profile = try AppleLocalAIProfile(
      model: ToolCallResponseModel(),
      tools: [PreflightProbeTool(calls: toolCalls)],
      toolCallingMode: .required,
      toolCallPreflight: { _ in
        await preflightCalls.increment()
        throw EffectError.failed
      },
    )
    let session = AppleLocalAISession(profile: profile)

    var failed = false
    do {
      _ = try await session.respond(AppleLocalAIRequest(text: "Run the probe"))
    } catch {
      failed = true
    }

    #expect(failed)
    #expect(await preflightCalls.value == 1)
    #expect(await toolCalls.value == 0)
    #expect(session.phase == .idle)
  }
}

private enum EffectError: Error { case failed, nativeFailure }

private enum StreamKind: CaseIterable { case text, asyncText, generated, schema }

@Generable
private struct StreamAnswer: Sendable {
  var answer: String
}

/// A controllable native executor fixture. This is framework integration
/// evidence, not proof of actual model inference. Identity also keeps the native
/// executor cache from sharing a gate between tests.
@MainActor
private final class SuspendedResponse: Hashable {
  private var continuation: CheckedContinuation<Void, Never>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  private(set) var observedCancellation = false

  nonisolated static func == (lhs: SuspendedResponse, rhs: SuspendedResponse) -> Bool {
    lhs === rhs
  }

  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started = true
      startedContinuation?.resume()
      startedContinuation = nil
    }
    observedCancellation = Task.isCancelled
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startedContinuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct SuspendedResponseModel: LanguageModel {
  typealias Executor = SuspendedResponseExecutor
  let effect: SuspendedResponse
  var executorConfiguration: SuspendedResponse { effect }
  var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
}

private struct SuspendedResponseExecutor: LanguageModelExecutor {
  typealias Model = SuspendedResponseModel
  let effect: SuspendedResponse

  init(configuration: SuspendedResponse) { effect = configuration }

  func prewarm(model: Model, transcript: Transcript) {}

  nonisolated(nonsending) func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    await effect.wait()
    await channel.send(.response(action: .appendText("settled", tokenCount: 1)))
  }
}

private struct FixedResponseModel: LanguageModel {
  typealias Executor = FixedResponseExecutor
  let executorConfiguration: FixedResponseExecutor.Configuration
  var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }

  init(
    _ response: String,
    failsAfterResponse: Bool = false
  ) {
    executorConfiguration = .init(
      response: response,
      failsAfterResponse: failsAfterResponse)
  }
}

private struct GenerationPolicyProbeModel: LanguageModel {
  typealias Executor = GenerationPolicyProbeExecutor

  let expectedTemperature: Double
  let expectedMaximumResponseTokens: Int
  let expectsLightReasoning: Bool

  var capabilities: LanguageModelCapabilities {
    LanguageModelCapabilities([.reasoning])
  }

  var executorConfiguration: GenerationPolicyProbeExecutor.Configuration {
    .init(
      expectedTemperature: expectedTemperature,
      expectedMaximumResponseTokens: expectedMaximumResponseTokens,
      expectsLightReasoning: expectsLightReasoning)
  }
}

private struct GenerationPolicyProbeExecutor: LanguageModelExecutor {
  typealias Model = GenerationPolicyProbeModel

  struct Configuration: Hashable, Sendable {
    let expectedTemperature: Double
    let expectedMaximumResponseTokens: Int
    let expectsLightReasoning: Bool
  }

  private let configuration: Configuration

  init(configuration: Configuration) {
    self.configuration = configuration
  }

  func prewarm(model: Model, transcript: Transcript) {}

  func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    #expect(request.generationOptions.temperature == configuration.expectedTemperature)
    #expect(
      request.generationOptions.maximumResponseTokens
        == configuration.expectedMaximumResponseTokens)
    #expect(request.generationOptions.samplingMode == .greedy)
    #expect(configuration.expectsLightReasoning)
    #expect(request.contextOptions.reasoningLevel == .light)
    #expect(request.generationOptions.toolCallingMode?.kind == .allowed)
    await channel.send(.response(action: .appendText("policy-forwarded", tokenCount: 1)))
  }
}

private actor CallCounter {
  private var count = 0

  var value: Int { count }

  func increment() { count += 1 }
}

private struct PreflightProbeTool: Tool {
  let name = "probe"
  let description = "A test tool that records whether its implementation ran."
  let calls: CallCounter

  @Generable struct Arguments {}

  func call(arguments: Arguments) async throws -> String {
    await calls.increment()
    return "executed"
  }
}

private struct ToolCallResponseModel: LanguageModel {
  typealias Executor = ToolCallResponseExecutor
  let executorConfiguration = "probe"
  var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }
}

private struct ToolCallResponseExecutor: LanguageModelExecutor {
  typealias Model = ToolCallResponseModel

  private let configuration: String

  init(configuration: String) { self.configuration = configuration }

  func prewarm(model: Model, transcript: Transcript) {}

  func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    await channel.send(
      .toolCalls(
        action: .toolCall(
          id: configuration, name: "probe",
          action: .appendArguments("{}", tokenCount: 1))))
  }
}

private struct FixedResponseExecutor: LanguageModelExecutor {
  typealias Model = FixedResponseModel

  struct Configuration: Hashable, Sendable {
    let response: String
    let failsAfterResponse: Bool
  }

  let configuration: Configuration

  func prewarm(model: Model, transcript: Transcript) {}

  nonisolated(nonsending) func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    await channel.send(.response(action: .appendText(configuration.response, tokenCount: 1)))
    if configuration.failsAfterResponse { throw EffectError.nativeFailure }
  }
}
