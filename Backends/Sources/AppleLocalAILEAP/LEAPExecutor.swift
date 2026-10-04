import Foundation
import FoundationModels
import os

private let leapExecutorLogger = Logger(
  subsystem: "AppleLocalAI",
  category: "LEAPExecutor")

/// Bridges one actor-owned LEAP generation into Apple's executor channel.
/// No native LEAP type crosses this file's public boundary.
@available(iOS 27.0, macOS 27.0, *)
public struct LEAPExecutor: LanguageModelExecutor {
  public typealias Model = LEAPLanguageModel

  final class Handle: Sendable, Hashable {
    let runtime: AppleLocalAILEAPRuntime

    init(runtime: AppleLocalAILEAPRuntime) {
      self.runtime = runtime
    }

    static func == (lhs: Handle, rhs: Handle) -> Bool {
      lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(self))
    }
  }

  public struct Configuration: Hashable, Sendable {
    fileprivate let handle: Handle
    fileprivate let model: AppleLocalAILEAPTextModel

    init(runtime: AppleLocalAILEAPRuntime, model: AppleLocalAILEAPTextModel) {
      self.handle = Handle(runtime: runtime)
      self.model = model
    }

    public static func == (lhs: Configuration, rhs: Configuration) -> Bool {
      lhs.handle == rhs.handle && lhs.model == rhs.model
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(handle)
      hasher.combine(model)
    }
  }

  private let configuration: Configuration

  public init(configuration: Configuration) throws {
    self.configuration = configuration
  }

  public func prewarm(model: Model, transcript: Transcript) {
    // Foundation Models makes this callback synchronous. The actor owns the
    // asynchronous native probe and coalesces repeated callbacks. The model
    // and transcript arguments are intentionally not projected into the
    // public session: the probe uses a private native conversation.
    _ = model
    _ = transcript
    let runtime = configuration.handle.runtime
    let nativeModel = configuration.model
    Task {
      do {
        try await runtime.prewarmTextModel(model: nativeModel)
      } catch is CancellationError {
        return
      } catch {
        leapExecutorLogger.error("LEAP native prewarm failed: \(String(describing: error))")
      }
    }
  }

  public nonisolated(nonsending) func respond(
    to request: LanguageModelExecutorGenerationRequest,
    model: Model,
    streamingInto channel: LanguageModelExecutorGenerationChannel
  ) async throws {
    try Task.checkCancellation()
    let plan = try LEAPTranscriptPlan.make(from: request)
    let collector = LEAPResponseCollector()

    try await configuration.handle.runtime.generate(
      model: configuration.model,
      plan: plan
    ) { event in
      switch event {
      case .textDelta(let delta):
        guard !Task.isCancelled else { return }
        await collector.append(delta)
        // Guided output is buffered until the native terminal event so a
        // malformed JSON prefix can never be committed as a successful answer.
        guard !Task.isCancelled, plan.schemaJSON == nil else { return }
        await channel.send(
          .response(
            action: .appendText(
              delta,
              // LEAP reports exact completion usage only at its terminal event.
              // Zero here avoids presenting UTF-8 bytes as tokenizer output;
              // the final updateUsage event carries the exact native totals.
              tokenCount: 0)))
      case .completed(let usage):
        guard !Task.isCancelled else { return }
        await collector.complete(usage: usage)
      }
    }

    try Task.checkCancellation()
    let result = await collector.result()
    try Task.checkCancellation()
    guard case .completed(let usage) = result.completion, !result.text.isEmpty else {
      throw AppleLocalAILEAPError.invalidRuntimeOutput
    }
    if plan.schemaJSON != nil {
      guard let data = result.text.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data, options: []),
        object is [String: Any]
      else {
        throw AppleLocalAILEAPError.invalidRuntimeOutput
      }
      try Task.checkCancellation()
      await channel.send(
        .response(
          action: .appendText(
            result.text,
            tokenCount: 0)))
    }
    if let usage {
      let inputTokenCount = usage.promptTokens + usage.cachedPromptTokens
      try Task.checkCancellation()
      await channel.send(
        .response(
          action: .updateUsage(
            input: .init(
              totalTokenCount: inputTokenCount,
              cachedTokenCount: usage.cachedPromptTokens),
            output: .init(
              totalTokenCount: usage.completionTokens,
              reasoningTokenCount: 0))))
    }
  }
}

actor LEAPResponseCollector {
  enum Completion: Sendable, Equatable {
    case collecting
    case completed(LEAPGenerationUsage?)
  }
  private var textParts = [String]()
  private var completion = Completion.collecting

  func append(_ value: String) {
    guard !Task.isCancelled, !value.isEmpty else { return }
    textParts.append(value)
  }

  func complete(usage: LEAPGenerationUsage?) {
    completion = .completed(usage)
  }

  func result() -> (text: String, completion: Completion) {
    (textParts.joined(), completion)
  }
}
