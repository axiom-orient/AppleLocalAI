import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAI

/// Opt-in qualification of the actual OS 27 SDK path, not a fixed executor fixture.
@Suite(
  "Native OS 27 system integration",
  .enabled(
    if: ProcessInfo.processInfo.environment["APPLELOCALAI_RUN_NATIVE_INFERENCE"] == "1",
    "Set APPLELOCALAI_RUN_NATIVE_INFERENCE=1 to run Apple's actual system model."),
  .enabled(
    if: SystemLanguageModel.default.availability == .available,
    "Apple Intelligence is unavailable; actual inference is not qualified."))
@MainActor
struct NativeSystemIntegrationTests {
  @Test("Native system response, stream, cancellation, reuse and profile lifecycle")
  func nativeSystemLifecycle() async throws {
    var evidence = NativeSystemEvidence()
    do {
      try persist(evidence)
      let profile = try AppleLocalAIProfile(
        model: SystemLanguageModel.default, instructions: "Answer briefly.",
        maximumResponseTokens: 96)
      let session = AppleLocalAISession(profile: profile)
      let response = try await session.respond(
        AppleLocalAIRequest(text: "Say hello in one short sentence."))
      try #require(!response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      try #require(response.usage.output.totalTokenCount > 0)
      try #require(session.phase == .idle)
      let firstHistory = session.history
      try #require(!firstHistory.isEmpty)
      evidence.record("respond", response.content)
      try persist(evidence)

      var snapshots = 0
      var finalText = ""
      let streamed = try await session.stream(
        AppleLocalAIRequest(text: "Name one common fruit in a short sentence.")
      ) { snapshot in
        snapshots += 1
        finalText = snapshot.text
      }
      try #require(snapshots > 0 && !streamed.text.isEmpty && finalText == streamed.text)
      try #require(streamed.usage.output.totalTokenCount > 0)
      try #require(Array(session.history.prefix(firstHistory.count)) == firstHistory)
      try #require(
        Array(session.history.suffix(streamed.transcriptEntries.count))
          == streamed.transcriptEntries)
      evidence.record("stream", "\(snapshots) snapshots; \(streamed.text)")
      try persist(evidence)

      let generation = Task { @MainActor in
        try await session.stream(
          AppleLocalAIRequest(
            text: "Explain photosynthesis in twenty numbered paragraphs with detailed examples."),
          options: GenerationOptions(maximumResponseTokens: 2_048)
        ) { _ in }
      }
      var cancelledWhileRunning = false
      let watcher = Task { @MainActor in
        while session.phase == .idle {
          guard !Task.isCancelled else { return }
          await Task.yield()
        }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        guard !Task.isCancelled, session.phase == .running else { return }
        cancelledWhileRunning = true
        session.cancel()
      }
      let terminal = await withTaskCancellationHandler {
        await generation.result
      } onCancel: {
        generation.cancel()
      }
      watcher.cancel()
      await watcher.value
      try Task.checkCancellation()
      try #require(cancelledWhileRunning)
      switch terminal {
      case .success:
        Issue.record(
          "Native SDK generation completed without observing the requested cancellation.")
        throw NativeSystemQualificationError.cancellationNotObserved
      case .failure(let error):
        try #require(error as? AppleLocalAIError == .cancelled)
      }
      try #require(session.phase == .idle && !session.isBusy)
      evidence.record(
        "cancel-and-settle", "Cancelled while SDK phase was running; idle after task settlement")
      try persist(evidence)

      let reused = try await session.respond(
        AppleLocalAIRequest(text: "Name one common color in a short sentence."))
      try #require(!reused.content.isEmpty && session.phase == .idle)
      try #require(lastResponse(in: session.history) == reused.content)
      evidence.record("reuse-after-cancel", reused.content)
      try persist(evidence)

      let generated = try await session.generate(
        AppleLocalAIRequest(text: "Put the name of one common fruit in the answer field."),
        generating: NativeSystemAnswer.self)
      try #require(!generated.content.answer.isEmpty && generated.usage.output.totalTokenCount > 0)
      evidence.record("structured-generation", generated.content.answer)
      try persist(evidence)

      let history = session.history
      try session.reconfigure(
        AppleLocalAIProfile(
          model: SystemLanguageModel.default, instructions: "Give one short sentence.",
          maximumResponseTokens: 96))
      let reconfigured = try await session.respond(
        AppleLocalAIRequest(text: "Say goodbye."))
      try #require(!reconfigured.content.isEmpty)
      try #require(Array(session.history.prefix(history.count)) == history)
      let completedHistory = session.history
      try session.clearProfile()
      try #require(session.activeModel == nil && session.history == completedHistory)
      try session.reset(profile: profile)
      try #require(session.history.isEmpty && session.phase == .idle)
      evidence.record(
        "profile-and-reset",
        "History preserved across profile changes; explicit reset starts a new conversation")

      let invocations = NativeToolInvocations()
      let tool = NativeQualificationTool(invocations: invocations)
      let toolProfile = try AppleLocalAIProfile(
        model: SystemLanguageModel.default,
        instructions:
          "Call qualificationEcho with token applelocalai-verified, then repeat its result.",
        tools: [tool], maximumResponseTokens: 128, toolCallingMode: .required,
      )
      let toolSession = AppleLocalAISession(profile: toolProfile)
      let toolResponse = try await toolSession.respond(
        AppleLocalAIRequest(text: "Verify the token using qualificationEcho."))
      let performed = await invocations.tokens
      try #require(!performed.isEmpty && performed.allSatisfy { $0 == "applelocalai-verified" })
      try #require(!toolResponse.content.isEmpty && !toolSession.isBusy)
      evidence.record("native-tool-execution", "\(performed.count) actual native tool callbacks")
      try persist(evidence)

      try toolSession.reset(
        profile: AppleLocalAIProfile(
          model: SystemLanguageModel.default,
          instructions: "Call qualificationEcho with token applelocalai-verified.",
          tools: [tool], maximumResponseTokens: 128, toolCallingMode: .required,
          toolCallPolicy: .handoff))
      do {
        _ = try await toolSession.respond(
          AppleLocalAIRequest(text: "Verify the token using qualificationEcho."))
        throw NativeSystemQualificationError.handoffNotObserved
      } catch let handoff as AppleLocalAIToolHandoff {
        try #require(handoff.call.toolName == tool.name)
      } catch let wrapped as LanguageModelSession.ToolCallError {
        let handoff = try #require(wrapped.underlyingError as? AppleLocalAIToolHandoff)
        try #require(handoff.call.toolName == tool.name)
      }
      try #require(await invocations.tokens == performed)
      try #require(!toolSession.isBusy)
      evidence.record(
        "native-tool-handoff", "Native tool call returned without executing its effect")
      try persist(evidence)
      evidence.outcome = "PASS"
      try persist(evidence)
    } catch {
      evidence.outcome = "FAIL"
      evidence.error = String(describing: error)
      do { try persist(evidence) } catch {
        Issue.record("Could not write native qualification evidence: \(error)")
      }
      throw error
    }
  }

  private func persist(_ evidence: NativeSystemEvidence) throws {
    guard let path = ProcessInfo.processInfo.environment["APPLELOCALAI_NATIVE_EVIDENCE_PATH"] else {
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(evidence).write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  private func lastResponse(in history: [Transcript.Entry]) -> String? {
    for entry in history.reversed() {
      if case .response(let response) = entry {
        return response.segments.compactMap { segment in
          if case .text(let text) = segment { text.content } else { nil }
        }.joined()
      }
    }
    return nil
  }
}

@Generable
private struct NativeSystemAnswer {
  let answer: String
}

private struct NativeSystemEvidence: Encodable {
  struct Check: Encodable {
    let name: String
    let details: String
  }
  let runID = UUID()
  let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  let provider = "Root AppleLocalAISession / Apple SystemLanguageModel.default"
  var outcome = "RUNNING"
  var checks: [Check] = []
  var error: String?

  mutating func record(_ name: String, _ details: String) {
    checks.append(.init(name: name, details: details))
  }
}

private enum NativeSystemQualificationError: Error {
  case cancellationNotObserved
  case handoffNotObserved
}

private actor NativeToolInvocations {
  private(set) var tokens: [String] = []

  func record(_ token: String) { tokens.append(token) }
}

private struct NativeQualificationTool: Tool {
  let name = "qualificationEcho"
  let description = "Returns the supplied verification token."
  let invocations: NativeToolInvocations

  @Generable struct Arguments {
    let token: String
  }

  func call(arguments: Arguments) async throws -> String {
    await invocations.record(arguments.token)
    return arguments.token
  }
}
