#if os(macOS)
  import AppleLocalAI
  import AppleLocalAIHost
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels
  import Testing
  @testable import AppleLocalAIWire
  @testable import AppleLocalAIProvider

  @Test func normalizedSessionCancellationUsesClientCancelledStatus() {
    for error in [
      asWireError(AppleLocalAIError.cancelled),
      asWireError(CancellationError()),
    ] {
      #expect(error.status == 499)
      #expect(error.code == "request_cancelled")
    }
  }

  /// These fixtures validate the REAL Foundation Models dispatch/translation path,
  /// not any production model's quality, readiness, Metal kernels or account access.
  private actor RequestWitness {
    var entries: [Transcript.Entry] = []
    func record(_ transcript: Transcript) { entries = Array(transcript) }
  }
  private struct GatewayProbe: LanguageModel {
    let emitsTool: Bool
    let witness: RequestWitness
    let id = UUID().uuidString
    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    var executorConfiguration: String { id }
    struct Executor: LanguageModelExecutor {
      typealias Model = GatewayProbe
      init(configuration: String) {}
      func respond(
        to request: LanguageModelExecutorGenerationRequest, model: Model,
        streamingInto channel: LanguageModelExecutorGenerationChannel
      ) async throws {
        await model.witness.record(request.transcript)
        await channel.send(
          .response(
            action: .updateUsage(
              input: .init(totalTokenCount: 8, cachedTokenCount: 0),
              output: .init(totalTokenCount: 3, reasoningTokenCount: 0))))
        if model.emitsTool {
          await channel.send(
            .toolCalls(
              action: .toolCall(
                id: "call-native", name: "read",
                action: .appendArguments(#"{"path":"a"}"#, tokenCount: 3))))
        } else {
          await channel.send(.response(action: .appendText("answer", tokenCount: 3)))
        }
      }
    }
  }

  @Test @MainActor func nativeToolCallbackReturnsCallWithoutExecutingClientTool() async throws {
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"probe","input":"read a","tools":[{"type":"function","name":"read","parameters":{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"}},"required":["path"]}}]}"#
          .utf8))
    let model = GatewayProbe(emitsTool: true, witness: RequestWitness())
    let result = try await NativeRequestExecutor.generate(
      request: request,
      profile: .init(id: "probe", backend: .system), model: model, onSnapshot: { _, _ in })
    #expect(
      result.calls == [
        .init(id: "call-native", name: "read", arguments: .object(["path": .string("a")]))
      ])
    // ClientOwnedTool.call throws tool_authority_violation; reaching this result
    // proves the native onToolCall callback stopped dispatch before execution.
  }

  @Test @MainActor func unsupportedToolSchemaFailsBeforeNativeSession() async throws {
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"probe","input":"read a","tools":[{"type":"function","name":"read","parameters":{"type":"object","additionalProperties":false,"properties":[]}}]}"#
          .utf8))
    let witness = RequestWitness()

    do {
      _ = try await NativeRequestExecutor.generate(
        request: request,
        profile: .init(id: "probe", backend: .system),
        model: GatewayProbe(emitsTool: true, witness: witness), onSnapshot: { _, _ in })
      Issue.record("Invalid JSON Schema must fail before native generation")
    } catch let error as WireError {
      #expect(error.status == 422)
    }
    #expect(await witness.entries.isEmpty)
  }

  @Test @MainActor func toolContinuationDoesNotInventAnEmptyUserTurn() async throws {
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"probe","input":[{"role":"user","content":"read a"},{"type":"function_call","call_id":"c","name":"read","arguments":"{\"path\":\"a\"}"},{"type":"function_call_output","call_id":"c","output":"result"}]}"#
          .utf8))
    let witness = RequestWitness()
    let result = try await NativeRequestExecutor.generate(
      request: request,
      profile: .init(id: "probe", backend: .system),
      model: GatewayProbe(emitsTool: false, witness: witness), onSnapshot: { _, _ in })
    #expect(result.text == "answer")
    let entries = await witness.entries
    guard case .toolOutput(let output) = entries.last else {
      Issue.record("Effective transcript must end in the real tool output")
      return
    }
    #expect(output.id == "c")
    #expect(output.toolName == "read")
    #expect(entries.filter { if case .prompt = $0 { true } else { false } }.count == 1)
  }

  @Test @MainActor func nativeHistoryPreservesArgumentsAndToolIdentifiers() throws {
    let history = try NativeRequestExecutor.nativeHistory([
      .user("read"),
      .toolCall(.init(id: "a", name: "read", arguments: .object(["path": .string("file")]))),
      .toolResult(id: "a", name: "read", text: "result"),
    ])
    guard case .toolCalls(let calls) = history[1], let call = calls.first else {
      Issue.record("Missing native calls")
      return
    }
    #expect(call.id == "a")
    #expect(call.toolName == "read")
    #expect(try call.arguments.value(String.self, forProperty: "path") == "file")
    guard case .toolOutput(let output) = history[2] else {
      Issue.record("Missing output")
      return
    }
    #expect(output.id == call.id)
  }

  @Test func declaredCapabilitiesCannotGrantMissingNativeCapability() {
    #expect(
      capabilityCeiling([.vision, .toolCalling], actual: [.toolCalling]) == [.toolCalling])
    #expect(capabilityCeiling(nil, actual: [.vision]) == [.vision])
  }

  @Test @MainActor func manualProviderSelectionPreservesRequestCapabilities() throws {
    let configuration = ProviderConfiguration(
      port: 8765,
      tokenEnvironment: "TOKEN",
      allowPrivateCloud: false,
      allowExternalNetwork: false,
      profiles: [
        .init(
          id: "text-only",
          backend: .chatCompletions,
          resource: "http://127.0.0.1:9000/v1",
          remoteModel: "text",
          capabilities: [])
      ])
    let catalog = ProviderModelCatalog(configuration: configuration, environment: [:])
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"text-only","input":"read","tools":[{"type":"function","name":"read","parameters":{"type":"object","additionalProperties":false,"properties":{}}}]}"#
          .utf8
      ))

    #expect(throws: ModelSelectionError.noEligibleModel) {
      try catalog.select(for: request)
    }
  }

  @Test @MainActor func undeclaredCoreAICapabilitiesAreCheckedAfterBundleLoad() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "applelocalai-coreai-selection-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let configuration = ProviderConfiguration(
      port: 8765,
      tokenEnvironment: "TOKEN",
      allowPrivateCloud: false,
      allowExternalNetwork: false,
      profiles: [
        .init(id: "core", backend: .coreAI, resource: directory.path)
      ])
    let catalog = ProviderModelCatalog(configuration: configuration, environment: [:])
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"core","input":"read","tools":[{"type":"function","name":"read","parameters":{"type":"object","additionalProperties":false,"properties":{}}}]}"#
          .utf8))

    #expect(try catalog.select(for: request).id == "core")
  }

  @Test @MainActor func profileReasoningPolicyIsAdmittedBeforeNativeLoad() throws {
    let configuration = ProviderConfiguration(
      port: 8765,
      tokenEnvironment: "TOKEN",
      allowPrivateCloud: false,
      allowExternalNetwork: false,
      profiles: [
        .init(
          id: "text-only",
          backend: .chatCompletions,
          resource: "http://127.0.0.1:9000/v1",
          remoteModel: "text",
          reasoning: "high",
          capabilities: [])
      ])
    let catalog = ProviderModelCatalog(configuration: configuration, environment: [:])
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(#"{"model":"text-only","input":"hello"}"#.utf8))

    #expect(throws: ModelSelectionError.noEligibleModel) {
      try catalog.select(for: request)
    }

    let override = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"text-only","input":"hello","reasoning":{"effort":"none"}}"#.utf8))
    #expect(try catalog.select(for: override).id == "text-only")
  }

  @Test @MainActor func upstreamCredentialUsesTheSharedHeaderPolicy() async throws {
    let configuration = ProviderConfiguration(
      port: 8765,
      tokenEnvironment: "TOKEN",
      allowPrivateCloud: false,
      allowExternalNetwork: false,
      profiles: [
        .init(
          id: "remote",
          backend: .chatCompletions,
          resource: "http://127.0.0.1:9000/v1",
          remoteModel: "remote-model",
          capabilities: [],
          credentialEnvironment: "UPSTREAM_KEY")
      ])
    let catalog = ProviderModelCatalog(
      configuration: configuration,
      environment: ["UPSTREAM_KEY": "credential\u{0085}value"])
    let profile = try #require(configuration.profiles.first)

    do {
      _ = try await catalog.load(profile)
      Issue.record("Invalid upstream credentials must be rejected before model construction")
    } catch let error as WireError {
      #expect(error.code == "model_unavailable")
      #expect(error.message == "Configured upstream credential is missing or invalid")
    }
  }

  @Test @MainActor func liteRTUnsupportedOptionsFailBeforeModelLoad() throws {
    let profile = ProviderProfile(id: "lite", backend: .liteRT, resource: "/tmp/model.litertlm")
    let seeded = try InferenceRequest.decode(
      api: .chat,
      data: Data(
        #"{"model":"lite","messages":[{"role":"user","content":"hello"}],"seed":7}"#
          .utf8))
    let seededSchemas = try NativeRequestSchemas(request: seeded)
    #expect(throws: WireError.self) {
      try NativeProvider.validatePreloadConstraints(
        request: seeded, profile: profile, schemas: seededSchemas)
    }

    let mixed = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"lite","input":"hello","tools":[{"type":"function","name":"lookup","parameters":{"type":"object","additionalProperties":false,"properties":{}}}],"text":{"format":{"type":"json_schema","name":"answer","schema":{"type":"object","additionalProperties":false,"properties":{}}}}}"#
          .utf8))
    let mixedSchemas = try NativeRequestSchemas(request: mixed)
    #expect(throws: WireError.self) {
      try NativeProvider.validatePreloadConstraints(
        request: mixed, profile: profile, schemas: mixedSchemas)
    }

    let ordinary = try InferenceRequest.decode(
      api: .responses, data: Data(#"{"model":"lite","input":"hello"}"#.utf8))
    try NativeProvider.validatePreloadConstraints(
      request: ordinary, profile: profile, schemas: try NativeRequestSchemas(request: ordinary))
  }

  @Test @MainActor func sharedResourceIdentityNormalizesLiteRTPaths() throws {
    #expect(
      LocalModelResourceIdentity.normalizedFilePath(
        "  /tmp/model.litertlm \n") == "/tmp/model.litertlm")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleLocalAI-Provider-Identity-" + UUID().uuidString)
    let target = root.appendingPathComponent("target.litertlm")
    let link = root.appendingPathComponent("current.litertlm")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("model".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(LocalModelResourceIdentity.normalizedFilePath(link.path) == target.path)
  }

  @Test @MainActor func nativeUsageDeltaRejectsNonMonotonicCounters() throws {
    let before = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 3, reasoningTokenCount: 1))
    let after = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 16, cachedTokenCount: 2),
      output: .init(totalTokenCount: 6, reasoningTokenCount: 2))

    do {
      _ = try NativeRequestExecutor.usageDelta(before: before, after: after)
      Issue.record("Non-monotonic native usage must fail with a typed wire error")
    } catch let error as WireError {
      #expect(error.code == "invalid_usage")
      #expect(error.status == 502)
    }
  }

  @Test @MainActor func nativeUsageDeltaRejectsDecreasedInputCounter() throws {
    let before = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 3, reasoningTokenCount: 1))
    let after = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 9, cachedTokenCount: 4),
      output: .init(totalTokenCount: 4, reasoningTokenCount: 1))

    #expect(throws: WireError.self) {
      try NativeRequestExecutor.usageDelta(before: before, after: after)
    }
  }

  @Test @MainActor func nativeUsageDeltaReturnsNilWhenCountersDoNotChange() throws {
    let usage = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 3, reasoningTokenCount: 1))

    #expect(try NativeRequestExecutor.usageDelta(before: usage, after: usage) == nil)
  }

  @Test @MainActor func nativeUsageDeltaReportsOnlyTheRequestDelta() throws {
    let before = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 3, reasoningTokenCount: 1))
    let after = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 16, cachedTokenCount: 7),
      output: .init(totalTokenCount: 6, reasoningTokenCount: 2))

    let usage = try NativeRequestExecutor.usageDelta(before: before, after: after)
    let expected = try TokenUsage(input: 6, cachedInput: 3, output: 3, reasoning: 1)
    #expect(usage == expected)
  }

  @Test @MainActor func nativeStreamUsageDoesNotPublishCumulativeSessionCounts() throws {
    let before = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 3, reasoningTokenCount: 1))
    let after = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 16, cachedTokenCount: 7),
      output: .init(totalTokenCount: 6, reasoningTokenCount: 2))

    let usage = try NativeRequestExecutor.streamedUsageDelta(before: before, after: after)
    let expected = try TokenUsage(input: 6, cachedInput: 3, output: 3, reasoning: 1)
    #expect(usage == expected)
    #expect(usage?.input != after.input.totalTokenCount)
  }

  @Test @MainActor func nativeStreamUsageWaitsForMeasuredRequestInput() throws {
    let before = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 3, reasoningTokenCount: 1))
    let after = LanguageModelSession.Usage(
      input: .init(totalTokenCount: 10, cachedTokenCount: 4),
      output: .init(totalTokenCount: 6, reasoningTokenCount: 2))

    #expect(try NativeRequestExecutor.streamedUsageDelta(before: before, after: after) == nil)
  }

  @Test(arguments: [1, 2, 3]) @MainActor
  func smallHistoryWindowPreservesParallelToolContinuation(_ limit: Int) async throws {
    let request = try InferenceRequest.decode(
      api: .responses,
      data: Data(
        #"{"model":"probe","input":[{"role":"user","content":"read both"},{"type":"function_call","call_id":"a","name":"read","arguments":"{}"},{"type":"function_call","call_id":"b","name":"read","arguments":"{}"},{"type":"function_call_output","call_id":"a","output":"first"},{"type":"function_call_output","call_id":"b","output":"second"}]}"#
          .utf8))
    let witness = RequestWitness()
    _ = try await NativeRequestExecutor.generate(
      request: request, profile: .init(id: "probe", backend: .system, historyWindow: limit),
      model: GatewayProbe(emitsTool: false, witness: witness), onSnapshot: { _, _ in })
    let entries = await witness.entries
    let outputIDs = entries.compactMap { entry -> String? in
      if case .toolOutput(let output) = entry { return output.id }
      return nil
    }
    #expect(outputIDs == ["a", "b"])
    #expect(entries.filter { if case .prompt = $0 { true } else { false } }.count == 1)
    let callIDs = entries.flatMap { entry -> [String] in
      if case .toolCalls(let calls) = entry { return calls.map(\.id) }
      return []
    }
    #expect(callIDs == ["a", "b"])
  }
#endif
