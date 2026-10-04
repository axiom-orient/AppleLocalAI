import AppleLocalAI
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAILEAP

@Generable
private struct NativeAnswer {
  let word: String
}

/// Opt-in: uses the real pinned LEAP binary and verified weights. The root is
/// caller-owned; prepare downloads the pinned artifact only when missing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_LEAP_ROOT"] != nil))
@MainActor
func nativeLEAPTextLifecycle() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_LEAP_ROOT"])
  let runtime = try AppleLocalAILEAPRuntime(rootURL: URL(fileURLWithPath: path))
  let prepared = try await runtime.prepareTextModel()
  let model = try await runtime.makeTextModel(from: prepared)
  try await runtime.prewarmTextModel()
  let session = AppleLocalAISession(
    profile: try AppleLocalAIProfile(
      model: model, instructions: "Answer briefly.", maximumResponseTokens: 128))
  let response = try await session.respond(AppleLocalAIRequest(text: "Say hello."))
  #expect(!response.content.isEmpty)
  #expect(session.usage.output.totalTokenCount > 0)

  var snapshots = 0
  let streamed = try await session.stream(AppleLocalAIRequest(text: "Say goodbye.")) { _ in
    snapshots += 1
  }
  #expect(snapshots > 0)
  #expect(!streamed.text.isEmpty)
  let structured = try await session.generate(
    AppleLocalAIRequest(text: "Return the word hello."), generating: NativeAnswer.self)
  #expect(!structured.content.word.isEmpty)
  await #expect(throws: AppleLocalAIError.cancelled) {
    _ = try await session.stream(AppleLocalAIRequest(text: "Reply with one word: hello.")) { _ in
      session.cancel()
    }
  }
  #expect(session.phase == .idle)
  let afterCancellation = try await session.respond(AppleLocalAIRequest(text: "Say hello."))
  #expect(!afterCancellation.content.isEmpty)
  try await runtime.unload()
  await #expect(throws: AppleLocalAILEAPError.self) {
    try await runtime.prewarmTextModel()
  }
  // A verified file remains reusable after native residency is released.
  _ = try await runtime.makeTextModel(from: prepared)
  try await runtime.unload()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_LEAP_AUDIO_ROOT"] != nil))
func nativeLEAPAudioLifecycle() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_LEAP_AUDIO_ROOT"])
  let runtime = try AppleLocalAILEAPAudioRuntime(rootURL: URL(fileURLWithPath: path))
  let prepared = try await runtime.prepareAudioModel()
  let model = try await runtime.makeAudioModel(from: prepared)
  let response = try await model.generate(.synthesize(text: "Hello, world.", voice: .usFemale))
  let audio = try #require(response.audio)
  #expect(audio.sampleRate == 24_000)
  #expect(!audio.samples.isEmpty)
  #expect(try response.makeWAVData().count > 44)
  let input = try AppleLocalAILEAPAudioInput(pcmBuffer: response.makePCMBuffer())
  let transcription = try await model.generate(.transcribe(audio: input))
  #expect(!transcription.text.isEmpty)
  #expect(transcription.audio == nil)
  var textDeltas = ""
  var sampleCount = 0
  var completion: AppleLocalAILEAPAudioResponse?
  for try await event in model.stream(.speechToSpeech(audio: input)) {
    switch event {
    case .textDelta(let text): textDeltas.append(text)
    case .audio(let audio): sampleCount += audio.samples.count
    case .completed(let response):
      #expect(completion == nil)
      completion = response
    }
  }
  let spoken = try #require(completion)
  #expect(!spoken.text.isEmpty)
  #expect(spoken.text == textDeltas)
  #expect(sampleCount > 0)
  #expect(spoken.audio?.samples.count == sampleCount)
  try await runtime.unload()
  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await model.generate(.synthesize(text: "Hello", voice: .usFemale))
  }
}
