import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAISystem

@Suite("OS 26 system-model admission")
struct AppleLocalAISystemTests {
  @Test(
    "Every native unavailable reason is preserved",
    arguments: [
      SystemLanguageModel.Availability.UnavailableReason.deviceNotEligible,
      .appleIntelligenceNotEnabled,
      .modelNotReady,
    ])
  func unavailableReasonIsPreserved(
    reason: SystemLanguageModel.Availability.UnavailableReason
  ) {
    #expect(throws: AppleLocalAISystemError.unavailable(reason)) {
      try AppleLocalAISystem.requireAvailable(.unavailable(reason))
    }
    let description = AppleLocalAISystemError.unavailable(reason).errorDescription
    #expect(description?.isEmpty == false)
  }

  @Test("Available policy admits native construction")
  func availablePolicy() throws {
    try AppleLocalAISystem.requireAvailable(.available)
  }

  @Test(
    "An actually unavailable system model is rejected",
    .enabled(
      if: SystemLanguageModel.default.availability != .available,
      "The host system model is available; there is no native unavailable state to exercise."))
  func unavailableNativeModelIsRejected() throws {
    let model = SystemLanguageModel.default
    guard case .unavailable(let reason) = model.availability else {
      Issue.record("System model availability changed before the test ran.")
      return
    }
    #expect(throws: AppleLocalAISystemError.unavailable(reason)) {
      try AppleLocalAISystem.makeSession(model: model)
    }
  }

  @Test(
    "An actually available system model receives native tools and instructions",
    .enabled(
      if: SystemLanguageModel.default.availability == .available,
      "Apple Intelligence is unavailable on this host; native construction is not exercised."))
  func availableNativeSessionPreservesInputs() throws {
    // Constructs a real framework session without generating model output.
    let text = "Keep responses concise."
    let session = try AppleLocalAISystem.makeSession(
      tools: [ProbeTool()], instructions: Instructions(text))
    #expect(!session.isResponding)
    let entry = try #require(session.transcript.first)
    guard case .instructions(let instructions) = entry else {
      Issue.record("Native session did not retain its instructions entry.")
      return
    }
    #expect(instructions.toolDefinitions.map(\.name) == ["systemAdmissionProbe"])
    #expect(
      instructions.segments.contains { segment in
        if case .text(let value) = segment { value.content == text } else { false }
      })
  }

  @Test(
    "Opt-in real Apple system-model inference",
    .enabled(
      if: ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_SYSTEM_INFERENCE"] == "1",
      "Set APPLE_LOCAL_AI_SYSTEM_INFERENCE=1 to run actual system-model inference."),
    .enabled(
      if: SystemLanguageModel.default.availability == .available,
      "Apple Intelligence is unavailable; actual inference cannot run on this host."))
  func nativeSystemInference() async throws {
    let session = try AppleLocalAISystem.makeSession()
    let response = try await session.respond(to: "Name one common fruit.")
    #expect(!response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!session.isResponding)
  }
}

private struct ProbeTool: Tool {
  let name = "systemAdmissionProbe"
  let description = "A construction-only test tool; the test never invokes it."

  @Generable struct Arguments {}

  func call(arguments: Arguments) async throws -> String { "probe" }
}
