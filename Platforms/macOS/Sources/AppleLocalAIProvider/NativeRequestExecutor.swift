#if os(macOS)
  import AppleLocalAI
  import AppleLocalAIHost
  import AppleLocalAIWire
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels

  @MainActor
  enum NativeRequestExecutor {
    /// A request-local native session. Standard HTTP clients own their canonical
    /// conversation and replay it; there is deliberately no process-global chat.
    static func generate(
      request: InferenceRequest, profile: ProviderProfile, model: any LanguageModel,
      preparedSchemas: NativeRequestSchemas? = nil,
      onSnapshot: @escaping @Sendable (String, TokenUsage?) async throws -> Void
    ) async throws -> InferenceResult {
      var settings = FoundationModelsSettings.standard
      settings.maximumResponseTokens = request.maximumTokens
      settings.temperature = request.temperature
      if let topP = request.topP {
        settings.samplingMode = .randomProbabilityThreshold
        settings.probabilityThreshold = topP
      } else if request.temperature != nil || request.seed != nil {
        settings.samplingMode = .randomProbabilityThreshold
        settings.probabilityThreshold = 1
      }
      settings.randomSeed = request.seed
      let reasoning = request.reasoning ?? profile.reasoning ?? "none"
      switch reasoning {
      case "none": settings.reasoningLevel = .none
      case "low": settings.reasoningLevel = .light
      case "medium": settings.reasoningLevel = .moderate
      case "high": settings.reasoningLevel = .deep
      default: throw WireError.unsupported("Unsupported native reasoning policy")
      }
      let schemas = try preparedSchemas ?? NativeRequestSchemas(request: request)
      switch request.toolChoice {
      case .none:
        settings.toolCallingMode = .disallowed
      case .auto: settings.toolCallingMode = schemas.tools.isEmpty ? .disallowed : .allowed
      case .required: settings.toolCallingMode = .required
      case .named:
        settings.toolCallingMode = .required
      }
      let instructions = ([profile.instructions].compactMap { $0 } + request.instructions).joined(
        separator: "\n\n")
      let historyPolicy: AppleLocalAIHistoryPolicy =
        profile.historyWindow.map { .recentEntries($0) } ?? .full
      var entries = request.entries
      let prompt: Prompt
      let resumingTool: Bool
      if case .user(let text) = entries.last {
        entries.removeLast()
        prompt = Prompt(text)
        resumingTool = false
      } else {
        prompt = Prompt("")
        resumingTool = true
      }
      let history = try nativeHistory(entries)
      let aiProfile = try AppleLocalAIProfile(
        model: model,
        instructions: instructions,
        tools: schemas.tools,
        temperature: settings.temperature,
        samplingMode: settings.nativeSamplingMode,
        maximumResponseTokens: settings.maximumResponseTokens,
        reasoningLevel: settings.nativeReasoningLevel,
        toolCallingMode: settings.nativeToolCallingMode,
        toolCallPolicy: .handoff,
        transcriptErrorHandlingPolicy: .preserveTranscript,
        historyPolicy: historyPolicy,
        omitEmptyPromptFromHistory: resumingTool
      )
      let session = AppleLocalAISession(profile: aiProfile, history: history)
      let nativeRequest = AppleLocalAIRequest(prompt: prompt)
      let before = session.usage
      let inputHistoryCount = session.history.count
      var content = ""
      var calls = [WireToolCall]()
      let acceptsUsage = profile.backend != .liteRT
      do {
        if let nativeSchema = schemas.response {
          let response = try await session.generate(
            nativeRequest, schema: nativeSchema,
            options: settings.nativeGenerationOptions, contextOptions: settings.nativeContextOptions
          )
          guard response.content.isComplete else {
            throw WireError(
              status: 502, code: "incomplete_structured_output",
              message: "Native structured response did not complete")
          }
          content = response.content.jsonString
          try WireOutput.validateTextOutput(content, message: "Native output exceeded limit")
        } else {
          _ = try await session.streamAsync(
            nativeRequest,
            options: settings.nativeGenerationOptions,
            contextOptions: settings.nativeContextOptions
          ) { snapshot in
            try Task.checkCancellation()
            content = snapshot.text
            try WireOutput.validateTextOutput(content, message: "Native output exceeded limit")
            let snapshotUsage =
              acceptsUsage
              ? try streamedUsageDelta(before: before, after: snapshot.usage)
              : nil
            try await onSnapshot(content, snapshotUsage)
          }
        }
      } catch {
        let handoff: AppleLocalAIToolHandoff
        if let direct = error as? AppleLocalAIToolHandoff {
          handoff = direct
        } else if let wrapped = error as? LanguageModelSession.ToolCallError,
          let underlying = wrapped.underlyingError as? AppleLocalAIToolHandoff
        {
          // Foundation Models may wrap the canonical handoff marker in
          // ToolCallError. Unwrap only that marker; every other tool failure
          // remains a real inference failure.
          handoff = underlying
        } else {
          throw error
        }
        try Task.checkCancellation()
        // All calls already generated in the native turn are returned together.
        // Never discard siblings merely because the first callback stopped dispatch.
        var nativeCalls = session.history.dropFirst(inputHistoryCount).flatMap {
          entry -> [Transcript.ToolCall] in
          if case .toolCalls(let group) = entry { return Array(group) }
          return []
        }
        if !nativeCalls.contains(where: { $0.id == handoff.call.id }) {
          nativeCalls.append(handoff.call)
        }
        var ids = Set<String>()
        var toolArgumentBytes = 0
        calls = try nativeCalls.map { call in
          guard ids.insert(call.id).inserted, schemas.toolNames.contains(call.toolName)
          else {
            throw WireError(
              status: 502, code: "invalid_tool_call",
              message: "Native model emitted duplicate or unregistered tool calls")
          }
          let argumentsJSON = call.arguments.jsonString
          toolArgumentBytes = try WireOutput.addingToolArgumentBytes(
            toolArgumentBytes, json: argumentsJSON)
          let arguments = try JSONDecoder().decode(
            JSONValue.self, from: Data(argumentsJSON.utf8))
          guard arguments.object != nil else {
            throw WireError(
              status: 502, code: "invalid_tool_arguments",
              message: "Native tool arguments were not an object")
          }
          return WireToolCall(id: call.id, name: call.toolName, arguments: arguments)
        }
      }
      try Task.checkCancellation()
      guard !content.isEmpty || !calls.isEmpty else {
        throw WireError(status: 502, code: "empty_response", message: "Native response was empty")
      }
      try request.validateToolCallCardinality(calls)
      let after = session.usage
      let usage = acceptsUsage ? try usageDelta(before: before, after: after) : nil
      if request.api == .messages && usage == nil {
        throw WireError.unavailable(
          "Native backend did not report measured input usage required by Messages")
      }
      // Native success is authoritative. When measured usage reaches the requested
      // limit, conservatively report incomplete rather than claim a full answer.
      let hitLimit =
        calls.isEmpty
        && request.maximumTokens.map { limit in usage.map { $0.output >= limit } ?? false } == true
      return InferenceResult(text: content, calls: calls, usage: usage, hitOutputLimit: hitLimit)
    }

    static func nativeHistory(_ entries: [WireEntry]) throws -> [Transcript.Entry] {
      var result = [Transcript.Entry]()
      var pendingCalls = [Transcript.ToolCall]()
      func flushCalls() {
        if !pendingCalls.isEmpty {
          result.append(.toolCalls(.init(pendingCalls)))
          pendingCalls.removeAll()
        }
      }
      for entry in entries {
        if case .toolCall(let call) = entry {
          pendingCalls.append(
            .init(
              id: call.id, toolName: call.name,
              arguments: try GeneratedContent(json: call.arguments.jsonString())))
          continue
        }
        flushCalls()
        switch entry {
        case .user(let text): result.append(.prompt(.init(segments: [.text(.init(content: text))])))
        case .assistant(let text):
          result.append(.response(.init(segments: [.text(.init(content: text))])))
        case .toolResult(let id, let name, let text):
          result.append(
            .toolOutput(.init(id: id, toolName: name, segments: [.text(.init(content: text))])))
        case .toolCall: break
        }
      }
      flushCalls()
      return result
    }

    static func usageDelta(
      before: LanguageModelSession.Usage,
      after: LanguageModelSession.Usage
    ) throws -> TokenUsage? {
      let input = after.input.totalTokenCount.subtractingReportingOverflow(
        before.input.totalTokenCount)
      let cachedInput = after.input.cachedTokenCount.subtractingReportingOverflow(
        before.input.cachedTokenCount)
      let output = after.output.totalTokenCount.subtractingReportingOverflow(
        before.output.totalTokenCount)
      let reasoning = after.output.reasoningTokenCount.subtractingReportingOverflow(
        before.output.reasoningTokenCount)
      guard !input.overflow, !cachedInput.overflow, !output.overflow, !reasoning.overflow else {
        throw WireError(
          status: 502,
          code: "invalid_usage",
          message: "Native backend returned non-monotonic token accounting")
      }
      let deltas = [
        input.partialValue, cachedInput.partialValue, output.partialValue, reasoning.partialValue,
      ]
      guard deltas.allSatisfy({ $0 >= 0 }) else {
        throw WireError(
          status: 502,
          code: "invalid_usage",
          message: "Native backend returned non-monotonic token accounting")
      }
      guard deltas.contains(where: { $0 > 0 }) else { return nil }
      return try TokenUsage(
        input: input.partialValue,
        cachedInput: cachedInput.partialValue,
        output: output.partialValue,
        reasoning: reasoning.partialValue)
    }

    static func streamedUsageDelta(
      before: LanguageModelSession.Usage,
      after: LanguageModelSession.Usage
    ) throws -> TokenUsage? {
      guard let delta = try usageDelta(before: before, after: after), delta.input > 0 else {
        return nil
      }
      return delta
    }
  }

  /// Application composition/admission. A busy provider fails promptly; it never
  /// interleaves clients in a shared session or starts overlapping weight loads.
  @MainActor
  final class NativeProvider {
    private let catalog: ProviderModelCatalog
    private var busy = false
    init(configuration: ProviderConfiguration, environment: [String: String]) {
      catalog = ProviderModelCatalog(configuration: configuration, environment: environment)
    }

    static func validatePreloadConstraints(
      request: InferenceRequest,
      profile: ProviderProfile,
      schemas: NativeRequestSchemas
    ) throws {
      guard profile.backend == .liteRT else { return }
      if request.seed != nil {
        throw WireError.unsupported("LiteRT does not support a random seed")
      }
      if request.schema != nil, !schemas.tools.isEmpty {
        throw WireError.unsupported(
          "LiteRT cannot enforce guided output and prompt-driven tool calling in the same turn")
      }
    }

    func perform(
      _ request: InferenceRequest,
      onSnapshot: @escaping @Sendable (String, TokenUsage?) async throws -> Void
    ) async throws -> InferenceResult {
      guard !busy else {
        throw WireError(
          status: 429, code: "provider_busy",
          message: "One native request is already running; retry after it finishes")
      }
      busy = true
      defer { busy = false }
      try Task.checkCancellation()
      let profile = try catalog.select(for: request)
      if profile.backend == .liteRT && request.api == .messages {
        throw WireError.unsupported(
          "LiteRT-LM 0.17 does not expose trustworthy token usage through this bridge. Use Chat/Responses; Messages is gated, not fabricated."
        )
      }
      if profile.backend == .liteRT && request.maximumTokens != nil {
        throw WireError.unsupported(
          "LiteRT-LM 0.17 can enforce an output-token cap but does not expose whether the cap or a natural stop ended generation. Omit the cap for Provider Chat/Responses or use a backend with a measurable terminal reason."
        )
      }
      // Reject unsupported/invalid schemas before model loading or cache eviction.
      let schemas = try NativeRequestSchemas(request: request)
      try Self.validatePreloadConstraints(request: request, profile: profile, schemas: schemas)
      let model = try await catalog.load(profile)
      var required = request.requirements
      if (request.reasoning ?? profile.reasoning ?? "none") != "none" {
        required.insert(.reasoning)
      }
      if request.model == "deep-reasoning" { required.insert(.reasoning) }
      guard required.isSubset(of: catalog.effectiveCapabilities(profile, model: model)) else {
        await catalog.releaseActive(profile: profile)
        throw WireError.unsupported(
          "Requested capabilities exceed the selected model's declared and native capabilities")
      }
      var effective = request
      if request.model == "deep-reasoning", effective.reasoning == nil {
        effective.reasoning = "high"
      }
      return try await NativeRequestExecutor.generate(
        request: effective, profile: profile, model: model,
        preparedSchemas: schemas, onSnapshot: onSnapshot)
    }
  }
#endif
