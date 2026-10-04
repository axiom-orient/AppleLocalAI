import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAILEAP

@Test func preparedArtifactIdentityResolvesSymlinkedRoots() throws {
  try withTemporaryDirectory { root in
    let target = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let alias = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

    #expect(LEAPPathIdentity.canonical(alias) == LEAPPathIdentity.canonical(target))
  }
}

@Generable
private struct StructuredAnswer {
  let value: String
}

@Test func pinsTheSmallestTextArtifact() {
  let model = AppleLocalAILEAPTextModel.default
  #expect(model == .lfm2_5_230M_q4_0)
  #expect(model.byteCount == 149_080_928)
  #expect(model.sha256.count == 64)
  #expect(model.remoteURL.absoluteString.contains(model.revision))
  #expect(AppleLocalAILEAP.leapSDKVersion == "0.10.13-SNAPSHOT")
}

@Test func pinsTheVersionMatchedAudioBundle() {
  let model = AppleLocalAILEAPAudioModelID.recommended
  #expect(model.artifactFiles.count == 3)
  #expect(model.requiredBytes == 1_063_770_528)
  #expect(model.artifactFiles.allSatisfy { $0.remoteURL.absoluteString.contains(model.revision) })
  #expect(model.artifactFiles.allSatisfy { $0.sha256.count == 64 })
}

@Test func mapsPortableTranscriptEntriesInsideTheFoundationModelsBoundary() throws {
  let transcript = Transcript(entries: [
    .instructions(
      .init(
        segments: [.text(.init(content: "Answer briefly."))],
        toolDefinitions: [])),
    .response(.init(segments: [.text(.init(content: "Earlier answer."))])),
    .prompt(.init(segments: [.text(.init(content: "Current question."))])),
  ])
  let plan = try LEAPTranscriptPlan.make(from: request(transcript: transcript))

  #expect(plan.messages.map(\.role) == [.system, .assistant])
  #expect(plan.messages.last?.content == "Earlier answer.")
  #expect(plan.userMessage == "Current question.")
  #expect(plan.maximumTokens == LEAPTranscriptPlan.defaultMaximumTokens)
}

@Test func rejectsInstructionsInsertedAfterConversationHistory() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Earlier question."))])),
    .instructions(
      .init(segments: [.text(.init(content: "Late policy."))], toolDefinitions: [])),
    .prompt(.init(segments: [.text(.init(content: "Current question."))])),
  ])

  #expect(throws: LanguageModelError.self) {
    _ = try LEAPTranscriptPlan.make(from: request(transcript: transcript))
  }
}

@Test func rejectsProviderOptionsThatWouldOtherwiseBeSilentlyIgnored() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Current question."))]))
  ])

  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(
        transcript: transcript,
        generationOptions: GenerationOptions(temperature: 0.2)))
  }

  #expect(throws: LanguageModelError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(
        transcript: transcript,
        contextOptions: ContextOptions(reasoningLevel: .light)))
  }
}

@Test func replaysGuidedResponseHistoryAsJSONForTheNextTurn() throws {
  let content = try GeneratedContent(json: #"{"value":"hello"}"#)
  let structure = Transcript.Segment.structure(.init(schemaName: "Answer", content: content))
  let transcript = Transcript(entries: [
    .response(.init(segments: [structure])),
    .prompt(.init(segments: [.text(.init(content: "Continue."))])),
  ])
  let plan = try LEAPTranscriptPlan.make(from: request(transcript: transcript))
  #expect(plan.messages == [.init(role: .assistant, content: content.jsonString)])
  #expect(plan.userMessage == "Continue.")
  #expect(throws: LanguageModelError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(
        transcript: Transcript(entries: [
          .prompt(.init(segments: [structure]))
        ])))
  }
}

@Test func rejectsToolsAtTheFoundationModelsBoundary() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Current question."))]))
  ])
  let tool = Transcript.ToolDefinition(
    name: "lookup",
    description: "Look up a value.",
    parameters: StructuredAnswer.generationSchema)

  #expect(throws: LanguageModelError.self) {
    _ = try LEAPTranscriptPlan.make(
      from: request(transcript: transcript, enabledTools: [tool]))
  }
}

@Test func rejectsUnsupportedAudioInputAtTheAppleAudioBoundary() {
  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try AppleLocalAILEAPAudioInput(samples: [], sampleRate: 16_000)
  }
  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try AppleLocalAILEAPAudioInput(
      samples: [2],
      sampleRate: 16_000)
  }
}

@Test func rejectsPromptHistoryThatExceedsTheUTF8Budget() {
  let transcript = Transcript(entries: [
    .prompt(
      .init(segments: [
        .text(
          .init(
            content: String(
              repeating: "x", count: LEAPTranscriptPlan.maximumPromptBytes + 1)))
      ]))
  ])

  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try LEAPTranscriptPlan.make(from: request(transcript: transcript))
  }
}

@Test func rejectsTranscriptEntryCountBeforeMaterializingHistory() {
  let entries: [Transcript.Entry] = (0...LEAPTranscriptPlan.maximumTranscriptEntries).map { _ in
    .reasoning(.init(segments: []))
  }
  let transcript = Transcript(entries: entries)

  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try LEAPTranscriptPlan.make(from: request(transcript: transcript))
  }
}

@Test func keepsNativeUsageCountsIndependentFromUTF8ByteCounts() {
  let usage = LEAPGenerationUsage(
    promptTokens: 29,
    cachedPromptTokens: 3,
    completionTokens: 5)

  #expect(usage.promptTokens == 29)
  #expect(usage.cachedPromptTokens == 3)
  #expect(usage.completionTokens == 5)
  #expect(usage.promptTokens + usage.cachedPromptTokens + usage.completionTokens == 37)
}

@Test func acceptsCachedTokensGreaterThanRecomputedPromptTokens() {
  let usage = LEAPGenerationUsage(
    nativePromptTokens: 2,
    nativeCachedPromptTokens: 29,
    nativeCompletionTokens: 5)

  #expect(usage?.promptTokens == 2)
  #expect(usage?.cachedPromptTokens == 29)
  #expect(usage?.completionTokens == 5)
}

@Test func rejectsMalformedNativeUsageMetadata() {
  #expect(
    LEAPGenerationUsage(
      nativePromptTokens: -1,
      nativeCachedPromptTokens: 0,
      nativeCompletionTokens: 1) == nil)
  #expect(
    LEAPGenerationUsage(
      nativePromptTokens: Int64.max,
      nativeCachedPromptTokens: 0,
      nativeCompletionTokens: Int64.max) == nil)
}

@Test func awaitedNativePrewarmFailsClosedBeforeModelLoad() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleLocalAI-LEAP-\(UUID().uuidString)", isDirectory: true)
  let runtime = try AppleLocalAILEAPRuntime(rootURL: root)

  await #expect(throws: AppleLocalAILEAPError.self) {
    try await runtime.prewarmTextModel()
  }
}

@Test func responseCollectorJoinsManyFragmentsWithoutChangingContent() async {
  let collector = LEAPResponseCollector()
  for _ in 0..<2_048 {
    await collector.append("a")
  }
  await collector.complete(usage: nil)

  let result = await collector.result()
  #expect(result.text == String(repeating: "a", count: 2_048))
  #expect(result.completion == .completed(nil))
}

@Test func cancelledTextCollectorDropsLateDeltas() async {
  let collector = LEAPResponseCollector()
  let cancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await collector.append("late")
  }
  await cancelled.value

  let result = await collector.result()
  #expect(result.text.isEmpty)
  #expect(result.completion == .collecting)
}

private func request(
  transcript: Transcript,
  enabledTools: [Transcript.ToolDefinition] = [],
  schema: GenerationSchema? = nil,
  generationOptions: GenerationOptions = .init(),
  contextOptions: ContextOptions = .init()
) -> LanguageModelExecutorGenerationRequest {
  LanguageModelExecutorGenerationRequest(
    id: UUID(),
    transcript: transcript,
    enabledTools: enabledTools,
    schema: schema,
    generationOptions: generationOptions,
    contextOptions: contextOptions,
    metadata: [:])
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AppleLocalAI-LEAP-Adapter-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}
