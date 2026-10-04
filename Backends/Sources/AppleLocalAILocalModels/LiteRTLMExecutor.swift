// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Parts of this implementation were originally authored by @john-rocky and
// ported from https://github.com/john-rocky/swift-litert-lm/tree/main.

#if canImport(FoundationModels) && compiler(>=6.4)

  import Foundation
  import FoundationModels
  @preconcurrency import LiteRTLM

  /// Drives LiteRT-LM generation through the Foundation Models executor contract.
  @available(iOS 27.0, macOS 27.0, *)
  public final class LiteRTLMExecutor: LanguageModelExecutor {
    public typealias Model = LiteRTLanguageModel

    /// The engine settings used to share one lazily loaded engine across sessions.
    public struct Configuration: Hashable, Sendable {
      public let engineConfig: EngineConfig

      public var modelPath: String { engineConfig.modelPath }

      public init(engineConfig: EngineConfig) {
        self.engineConfig = engineConfig
      }
    }

    /// The complete request translation that can be validated without native
    /// engine admission. Keeping this value separate from the engine lease
    /// prevents malformed transcript/schema input from loading model weights.
    struct PreparedGeneration {
      let tools: [Transcript.ToolDefinition]
      let schemaJSON: String?
      let plan: LiteRTTranscriptPlan
      let responseFormat: ResponseFormat?
    }

    private let engine: LazyEngine

    public init(configuration: Configuration) throws {
      self.engine = EngineCache.shared.engine(for: configuration)
    }

    public func prewarm(model: Model, transcript: Transcript) {
      Task {
        do {
          try await engine.prewarmed()
        } catch is CancellationError {
          return
        } catch {
          liteRTLogger.warning("LiteRT prewarm failed: \(String(describing: error))")
        }
      }
    }

    public func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: Model,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
      try Task.checkCancellation()
      try Self.validateContextOptions(request.contextOptions)
      try Self.validateToolDefinitions(
        request.generationOptions.toolCallingMode,
        count: request.enabledToolDefinitions.count)
      try Self.validateSchemaAndToolCombination(
        hasSchema: request.schema != nil,
        request.generationOptions.toolCallingMode,
        toolCount: request.enabledToolDefinitions.count)
      let maximumTokens = request.generationOptions.maximumResponseTokens
      if let maximumTokens, maximumTokens <= 0 || maximumTokens > Int(Int32.max) {
        throw LiteRTFMError.unsupported(
          "maximumResponseTokens is outside LiteRT's native Int32 range")
      }

      let sampler = try LiteRTSampler.make(request.generationOptions)
      let prepared = try Self.prepareGeneration(for: request)
      try Task.checkCancellation()
      let engine = try await engine.acquire()
      do {
        try await respond(
          using: engine,
          request: request,
          model: model,
          channel: channel,
          sampler: sampler,
          maximumTokens: maximumTokens,
          prepared: prepared)
        await self.engine.releaseUse()
      } catch {
        await self.engine.releaseUse()
        throw error
      }
    }

    private func respond(
      using engine: Engine,
      request: LanguageModelExecutorGenerationRequest,
      model: Model,
      channel: LanguageModelExecutorGenerationChannel,
      sampler: SamplerConfig?,
      maximumTokens: Int?,
      prepared: PreparedGeneration
    ) async throws {
      let tools = prepared.tools
      let schemaJSON = prepared.schemaJSON
      let plan = prepared.plan
      let responseFormat = prepared.responseFormat

      let conversation = try await engine.createConversation(
        with: ConversationConfig(
          systemMessage: plan.systemMessage,
          initialMessages: plan.history,
          samplerConfig: sampler,
          enableResponseFormat: responseFormat != nil,
          visualTokenBudget: model.visualTokenBudget))

      try await LiteRTGenerationLifecycle.run {
        try Task.checkCancellation()
        var emittedToolCall = false
        if !tools.isEmpty || schemaJSON != nil {
          var buffer = try LiteRTResponseBuffer(
            maximumBytes: LiteRTDefaults.maximumBufferedResponseBytes)
          for try await chunk in conversation.sendMessageStream(
            plan.prompt,
            maxOutputTokens: maximumTokens,
            responseFormat: tools.isEmpty ? responseFormat : nil)
          {
            try Task.checkCancellation()
            try buffer.append(chunk.toString)
          }
          try Task.checkCancellation()
          let full = buffer.text
          try buffer.requireNonEmptyResponse()

          let call =
            try tools.isEmpty
            ? nil
            : LiteRTToolCallEnvelope.parse(full, allowedNames: Set(tools.map(\.name)))
          if let call {
            emittedToolCall = true
            await channel.send(
              .toolCalls(
                action: .toolCall(
                  id: UUID().uuidString,
                  name: call.name,
                  action: .appendArguments(call.arguments, tokenCount: 0))))
          } else {
            try Self.validateToolCallResult(
              request.generationOptions.toolCallingMode,
              count: tools.count,
              emittedToolCall: false)
            if schemaJSON != nil {
              _ = try JSONSerialization.jsonObject(
                with: Data(full.utf8), options: [.fragmentsAllowed])
            }
            await channel.send(.response(action: .appendText(full, tokenCount: 0)))
          }
        } else {
          var outputBudget = try LiteRTResponseBuffer(
            maximumBytes: LiteRTDefaults.maximumBufferedResponseBytes)
          for try await chunk in conversation.sendMessageStream(
            plan.prompt,
            maxOutputTokens: maximumTokens)
          {
            try Task.checkCancellation()
            let delta = chunk.toString
            if !delta.isEmpty {
              try outputBudget.record(delta)
              // A native message chunk is not necessarily one tokenizer token.
              await channel.send(.response(action: .appendText(delta, tokenCount: 0)))
            }
          }
          try outputBudget.requireNonEmptyResponse()
        }
        try Task.checkCancellation()
        // The upstream runtime exposes exact counts only when the host has
        // opted into benchmark collection. Do not enable a global runtime flag
        // or invent counts from text when that information is unavailable.
        if ExperimentalFlags.enableBenchmark {
          do {
            let usage = try conversation.getBenchmarkInfo()
            guard usage.lastPrefillTokenCount >= 0, usage.lastDecodeTokenCount >= 0 else {
              liteRTLogger.warning("LiteRT returned invalid native token counts")
              return
            }
            let input = LanguageModelExecutorGenerationChannel.Usage.Input(
              totalTokenCount: usage.lastPrefillTokenCount, cachedTokenCount: 0)
            let output = LanguageModelExecutorGenerationChannel.Usage.Output(
              totalTokenCount: usage.lastDecodeTokenCount, reasoningTokenCount: 0)
            if emittedToolCall {
              await channel.send(.toolCalls(action: .updateUsage(input: input, output: output)))
            } else {
              await channel.send(.response(action: .updateUsage(input: input, output: output)))
            }
          } catch {
            liteRTLogger.warning(
              "LiteRT native token counts unavailable: \(String(describing: error))")
          }
        }
      } cancel: {
        do { try conversation.cancel() } catch {
          liteRTLogger.error("LiteRT native cancellation failed: \(String(describing: error))")
        }
      }
    }

    static func validateContextOptions(_ options: ContextOptions) throws {
      guard options.reasoningLevel == nil else {
        throw LanguageModelError.unsupportedCapability(
          .init(
            capability: .reasoning,
            debugDescription: "The LiteRT bridge does not map Foundation Models reasoning levels."))
      }
    }

    static func prepareGeneration(
      for request: LanguageModelExecutorGenerationRequest
    ) throws -> PreparedGeneration {
      let tools = try effectiveToolDefinitions(for: request)
      let schemaJSON: String?
      if let schema = request.schema {
        let encoded = try LiteRTTranscriptPlanner.encodeSchema(schema)
        guard !encoded.isEmpty else {
          throw LiteRTFMError.unsupported("The requested schema encoded to an empty value")
        }
        schemaJSON = encoded
      } else {
        schemaJSON = nil
      }

      let plan = try LiteRTTranscriptPlanner.make(
        from: request.transcript,
        schemaJSON: schemaJSON,
        tools: tools)
      let responseFormat: ResponseFormat?
      if let schemaJSON {
        responseFormat = try ResponseFormat.json(schema: schemaJSON)
      } else {
        responseFormat = nil
      }
      return PreparedGeneration(
        tools: tools,
        schemaJSON: schemaJSON,
        plan: plan,
        responseFormat: responseFormat)
    }

    static func validateToolDefinitions(
      _ mode: GenerationOptions.ToolCallingMode?, count: Int
    ) throws {
      try validateToolCount(count)
      if mode?.kind == .required, count == 0 {
        throw LiteRTFMError.unsupported(
          "Required LiteRT tool calling needs at least one enabled tool")
      }
    }

    static func validateToolCallResult(
      _ mode: GenerationOptions.ToolCallingMode?,
      count: Int,
      emittedToolCall: Bool
    ) throws {
      try validateToolDefinitions(mode, count: count)
      if mode?.kind == .required, !emittedToolCall {
        throw LiteRTFMError.invalidToolCall(
          "LiteRT did not emit a tool call for a required tool request")
      }
    }

    static func validateSchemaAndToolCombination(
      hasSchema: Bool,
      _ mode: GenerationOptions.ToolCallingMode?,
      toolCount: Int
    ) throws {
      try validateToolCount(toolCount)
      let effectiveToolCount = mode?.kind == .disallowed ? 0 : toolCount
      guard !hasSchema || effectiveToolCount == 0 else {
        throw LiteRTFMError.unsupported(
          "LiteRT cannot enforce guided output and prompt-driven tool calling in the same turn")
      }
    }

    private static func validateToolCount(_ count: Int) throws {
      guard count >= 0 else {
        throw LiteRTFMError.unsupported("LiteRT tool definition count must not be negative")
      }
      guard count <= LiteRTTranscriptPlanner.maximumToolDefinitions else {
        throw LiteRTFMError.unsupported(
          "LiteRT requests cannot contain more than "
            + String(LiteRTTranscriptPlanner.maximumToolDefinitions) + " tool definitions.")
      }
    }

    private static func effectiveToolDefinitions(
      for request: LanguageModelExecutorGenerationRequest
    ) throws -> [Transcript.ToolDefinition] {
      try validateToolDefinitions(
        request.generationOptions.toolCallingMode,
        count: request.enabledToolDefinitions.count)
      guard request.generationOptions.toolCallingMode?.kind != .disallowed else { return [] }
      return request.enabledToolDefinitions
    }

  }

#endif
