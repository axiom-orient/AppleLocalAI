#if os(macOS)

  import AppleLocalAI
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels
  import Testing

  @testable import AppleLocalAIMac

  /// Opt-in runtime qualification of the same response boundary used by the app.
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["APPLELOCALAI_RUN_NATIVE_INFERENCE"] == "1"),
    arguments: FoundationModelResponseMode.allCases
  )
  @MainActor
  func systemModelStreamsEveryResponseMode(mode: FoundationModelResponseMode) async throws {
    let model = SystemLanguageModel.default
    try #require(model.isAvailable)
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: model, maximumResponseTokens: 256))
    let schema = try mode == .dynamicSchema ? FoundationModelsResponseSchema.dynamic() : nil
    var snapshots = 0
    let answer = try await NativeResponseRunner.run(
      session: session,
      request: AppleLocalAIRequest(
        text:
          "Summarize briefly: The meeting starts at 3pm. Include one key point and no next actions."
      ),
      mode: mode,
      schema: schema,
      options: GenerationOptions(),
      contextOptions: ContextOptions(includeSchemaInPrompt: true),
      metadata: [:]
    ) { _ in snapshots += 1 }

    #expect(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(snapshots > 0)
    #expect(session.history.count == 2)
    #expect(session.phase == .idle)
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["APPLELOCALAI_RUN_NATIVE_INFERENCE"] == "1")
  )
  @MainActor
  func systemStreamCancellationSettlesBeforeReuse() async throws {
    let model = SystemLanguageModel.default
    try #require(model.isAvailable)
    let session = AppleLocalAISession(
      profile: try AppleLocalAIProfile(model: model, maximumResponseTokens: 256))
    var delivered = 0
    await #expect(throws: AppleLocalAIError.cancelled) {
      try await NativeResponseRunner.run(
        session: session,
        request: AppleLocalAIRequest(text: "Count from 1 to 40, using words."),
        mode: .text,
        schema: nil,
        options: GenerationOptions(),
        contextOptions: ContextOptions(),
        metadata: [:]
      ) { _ in
        delivered += 1
        session.cancel()
      }
    }
    #expect(delivered == 1)
    #expect(session.phase == .idle)
    let response = try await session.respond(AppleLocalAIRequest(text: "Reply with only READY."))
    #expect(!response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(session.phase == .idle)
  }

  /// Uses Foundation Models' real session and executor channel with fixed output.
  /// These are response-contract tests, not proof of model inference.
  @Suite("Native response execution")
  @MainActor
  struct NativeResponseRunnerTests {
    @Test func textPreservesOutputAndForwardsNativeSnapshots() async throws {
      let session = try makeSession(chunks: ["  hello", " world  "])
      var updates: [NativeResponseRunner.Snapshot] = []
      let answer = try await run(session, mode: .text) { updates.append($0) }

      #expect(answer == "  hello world  ")
      let finalUpdate = try #require(updates.last)
      #expect(finalUpdate.answer == answer)
      // Native stream snapshots contain the response entry, while committed
      // session history also contains the submitted prompt.
      #expect(finalUpdate.transcriptEntryCount == 1)
      #expect(finalUpdate.usage.input.totalTokenCount == session.usage.input.totalTokenCount)
      #expect(finalUpdate.usage.output.totalTokenCount == session.usage.output.totalTokenCount)
      #expect(session.history.count == 2)
      #expect(session.phase == .idle)
    }

    @Test(arguments: [FoundationModelResponseMode.typed, .dynamicSchema])
    func structuredModesValidateAndFormatTheSameContract(
      mode: FoundationModelResponseMode
    ) async throws {
      let content = FoundationModelsStructuredResponse(
        summary: "  answer  ", keyPoints: ["  one  ", "two"], nextActions: ["  act  "])
      let session = try makeSession(
        chunks: [content.generatedContent.jsonString], expectsSchema: true)
      var updates: [NativeResponseRunner.Snapshot] = []
      let answer = try await run(session, mode: mode) { updates.append($0) }

      #expect(answer == "answer\n\n핵심\n• one\n• two\n\n다음 단계\n• act")
      let finalUpdate = try #require(updates.last)
      let generated = try GeneratedContent(json: finalUpdate.answer)
      #expect(try generated.value(String.self, forProperty: "summary") == content.summary)
      #expect(finalUpdate.transcriptEntryCount == 1)
      #expect(session.phase == .idle)
    }

    @Test(arguments: [FoundationModelResponseMode.typed, .dynamicSchema])
    func emptyStructuredSummaryRetainsTheExactValidationError(
      mode: FoundationModelResponseMode
    ) async throws {
      let content = FoundationModelsStructuredResponse(
        summary: " \n ", keyPoints: [], nextActions: [])
      let session = try makeSession(
        chunks: [content.generatedContent.jsonString], expectsSchema: true)
      do {
        _ = try await run(session, mode: mode)
        Issue.record("An empty structured summary must fail validation")
      } catch AppleLocalAIModelError.invalidGenerationSchema(let message) {
        #expect(
          message
            == FoundationModelsResponseSchema.ValidationError.invalidContent.localizedDescription)
      }
      #expect(session.phase == .idle)
    }

    @Test func whitespaceTextRetainsTheEmptyResponseError() async throws {
      let session = try makeSession(chunks: [" \n "])
      do {
        _ = try await run(session, mode: .text)
        Issue.record("Whitespace response must fail validation")
      } catch AppleLocalAIModelError.emptyResponse {
        #expect(session.phase == .idle)
      }
    }

    @Test(arguments: [FoundationModelResponseMode.typed, .dynamicSchema])
    func truncatedStructuredOutputPreservesModeSpecificFailures(
      mode: FoundationModelResponseMode
    ) async throws {
      let session = try makeSession(chunks: [#"{"summary":"unfinished"#], expectsSchema: true)
      if mode == .typed {
        // Foundation Models cannot project this output into a typed snapshot.
        await #expect(throws: AppleLocalAIStreamError.emptyStream) {
          try await run(session, mode: mode)
        }
      } else {
        // Dynamic output reaches the schema decoder, whose native parser error
        // must retain the application's schema-error category and message.
        do {
          _ = try await run(session, mode: mode)
          Issue.record("Truncated dynamic output must fail validation")
        } catch AppleLocalAIModelError.invalidGenerationSchema(let message) {
          #expect(message == "Failed to parse generated content.")
        }
      }
      #expect(session.phase == .idle)
    }

    @Test func missingDynamicSchemaFailsBeforeNativeExecution() async throws {
      let session = try makeSession(chunks: ["unexpected"])
      var updates = 0
      do {
        _ = try await NativeResponseRunner.run(
          session: session,
          request: AppleLocalAIRequest(text: "hello"),
          mode: .dynamicSchema,
          schema: nil,
          options: GenerationOptions(),
          contextOptions: ContextOptions(),
          metadata: [:]
        ) { _ in updates += 1 }
        Issue.record("A dynamic response requires a schema")
      } catch AppleLocalAIModelError.invalidGenerationSchema(let message) {
        #expect(message == "dynamic schema is missing")
      }
      #expect(updates == 0)
      #expect(session.history.isEmpty)
      #expect(session.phase == .idle)
    }

    @Test func nativeFailurePropagatesWithoutResponseValidationReplacingIt() async throws {
      let session = try makeSession(chunks: [], fails: true)
      await #expect(throws: RunnerProbeError.failed) {
        try await run(session, mode: .text)
      }
      #expect(session.phase == .idle)
    }

    @Test func cancellingSnapshotDeliveryCannotReturnSuccessAndSessionCanBeReused() async throws {
      let session = try makeSession(chunks: ["hello", " world"])
      var updates = 0
      await #expect(throws: AppleLocalAIError.cancelled) {
        try await run(session, mode: .text) { _ in
          updates += 1
          session.cancel()
        }
      }
      #expect(updates == 1)
      #expect(session.phase == .idle)
      #expect(try await run(session, mode: .text) == "hello world")
    }

    private func makeSession(
      chunks: [String], expectsSchema: Bool = false, fails: Bool = false
    ) throws -> AppleLocalAISession {
      AppleLocalAISession(
        profile: try AppleLocalAIProfile(
          model: RunnerProbeModel(
            executorConfiguration: .init(
              chunks: chunks, expectsSchema: expectsSchema, fails: fails))))
    }

    private func run(
      _ session: AppleLocalAISession,
      mode: FoundationModelResponseMode,
      onSnapshot: @escaping @MainActor (NativeResponseRunner.Snapshot) -> Void = { _ in }
    ) async throws -> String {
      try await NativeResponseRunner.run(
        session: session,
        request: AppleLocalAIRequest(text: "hello"),
        mode: mode,
        schema: mode == .dynamicSchema ? FoundationModelsResponseSchema.dynamic() : nil,
        options: GenerationOptions(temperature: 0.25, maximumResponseTokens: 32),
        contextOptions: ContextOptions(includeSchemaInPrompt: false),
        metadata: ["probe": "forwarded"],
        onSnapshot: onSnapshot
      )
    }
  }

  private enum RunnerProbeError: Error { case failed }

  private struct RunnerProbeModel: LanguageModel {
    let executorConfiguration: Executor.Configuration
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }

    struct Executor: LanguageModelExecutor {
      typealias Model = RunnerProbeModel

      struct Configuration: Hashable, Sendable {
        let chunks: [String]
        let expectsSchema: Bool
        let fails: Bool
      }

      let configuration: Configuration

      func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
      ) async throws {
        if configuration.fails { throw RunnerProbeError.failed }
        #expect((request.schema != nil) == configuration.expectsSchema)
        #expect(request.generationOptions.temperature == 0.25)
        #expect(request.generationOptions.maximumResponseTokens == 32)
        #expect(request.contextOptions.includeSchemaInPrompt == false)
        #expect(try request.metadata["probe"]?.value(String.self) == "forwarded")
        for chunk in configuration.chunks {
          await channel.send(.response(action: .appendText(chunk, tokenCount: 1)))
        }
      }
    }
  }

#endif
