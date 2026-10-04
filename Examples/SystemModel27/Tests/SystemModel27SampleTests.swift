import AppleLocalAI
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAISystem27Sample

@MainActor
struct SystemModel27SampleTests {
  @Test("Live native readiness does not imply inference")
  func liveReadiness() {
    let model = SystemLanguageModel.default
    let readiness = AppleLocalAISystemReadiness(model: model)
    if case .unavailable = readiness.availability { #expect(!readiness.isReady) }
  }

  @Test(
    "Actual root OS 27 system lifecycle through the visible sample",
    .enabled(
      if: ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_SYSTEM27_INFERENCE_TESTS"] == "1",
      "Set APPLE_LOCAL_AI_SYSTEM27_INFERENCE_TESTS=1 for actual inference."))
  func actualLifecycle() async throws {
    let model = SystemModel27SampleModel()
    model.startVerification()
    await model.waitUntilIdle()
    let report = try #require(model.report)
    try #require(
      report.outcome == "INFERENCE_PASS", Comment(rawValue: report.error ?? report.outcome))
    #expect(
      report.checks.map(\.name) == [
        "respond", "stream", "cancel-and-settle", "reuse-after-cancel",
        "structured-generation", "profile-and-reset",
      ])
    #expect(!model.isWorking && !model.isSessionBusy)
    #expect(model.errorMessage == nil)
  }
}
