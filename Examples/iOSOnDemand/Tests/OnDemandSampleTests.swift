import XCTest

@testable import AppleLocalAIOnDemandSample

final class OnDemandSampleTests: XCTestCase {
  func testResponseValidationRejectsEmptyAndSpecialTokens() throws {
    XCTAssertThrowsError(try OnDemandModel.requireReadable("  "))
    XCTAssertThrowsError(try OnDemandModel.requireReadable("<|im_end|>"))
    XCTAssertThrowsError(try OnDemandModel.requireReadable("Hello <|im_end|>"))
    XCTAssertNoThrow(try OnDemandModel.requireReadable("Hello!"))
  }

  /// Explicit opt-in downloads and runs the pinned model inside the iOS host.
  /// No fixture or mock response qualifies this test.
  @MainActor
  func testRealOnDemandLifecycle() async throws {
    guard ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_ON_DEMAND_TESTS"] == "1" else {
      throw XCTSkip(
        "Set APPLE_LOCAL_AI_ON_DEMAND_TESTS=1 to download and run the real 149 MB model.")
    }
    let model = OnDemandModel()
    model.startVerification()
    await model.waitUntilIdle()
    let report = try XCTUnwrap(model.evidence)
    XCTAssertEqual(report.outcome, "PASS", report.error ?? "No failure details")
    XCTAssertEqual(
      report.checks.map(\.name),
      [
        "verified-download-and-load", "respond", "stream", "cancel-and-settle",
        "reuse-after-cancel", "unload", "cache-reload-and-respond", "final-unload",
      ])
    XCTAssertFalse(model.isLoaded)
    XCTAssertFalse(model.isWorking)
    XCTAssertNil(model.errorMessage)
  }
}
