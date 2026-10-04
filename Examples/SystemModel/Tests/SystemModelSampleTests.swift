import AppleLocalAISystem
import FoundationModels
import XCTest

@testable import AppleLocalAISystemSample

final class SystemModelSampleTests: XCTestCase {
  func testSimulatorMismatchDoesNotApplyToDevicesOrUnknownHosts() {
    XCTAssertFalse(
      SystemModelExecutionEnvironment(
        isSimulator: false, runtimeVersion: "26.5", hostVersion: "27.0.1"
      ).hasVersionMismatch)
    XCTAssertFalse(
      SystemModelExecutionEnvironment(
        isSimulator: true, runtimeVersion: "26.5", hostVersion: nil
      ).hasVersionMismatch)
    XCTAssertFalse(
      SystemModelExecutionEnvironment(
        isSimulator: true, runtimeVersion: "27.0", hostVersion: "27.0.1"
      ).hasVersionMismatch)
    XCTAssertFalse(
      SystemModelExecutionEnvironment(
        isSimulator: true, runtimeVersion: "26.5", hostVersion: "26.5"
      ).hasVersionMismatch)
    XCTAssertTrue(
      SystemModelExecutionEnvironment(
        isSimulator: true, runtimeVersion: "26.5", hostVersion: "27.0.1"
      ).hasVersionMismatch)
  }

  @MainActor
  func testHostVersionDoesNotOverrideNativeAdmission() throws {
    guard SystemModelExecutionEnvironment.current.hasVersionMismatch else {
      throw XCTSkip("This runtime and host do not have a known version mismatch.")
    }
    let model = SystemModelSampleModel()
    XCTAssertEqual(model.canRun, SystemLanguageModel.default.availability == .available)
    XCTAssertNil(model.report)
    XCTAssertFalse(model.isWorking)
    XCTAssertFalse(model.isNativeResponding)
  }

  @MainActor
  func testLiveNativeAvailabilityAndAdmission() throws {
    let model = SystemLanguageModel.default
    let before = model.availability
    do {
      let session = try AppleLocalAISystem.makeSession(model: model)
      guard model.availability == before else {
        throw XCTSkip(
          "Native availability changed during admission; rerun to compare the exact state.")
      }
      guard before == .available else {
        XCTFail("An unavailable native model admitted a session.")
        return
      }
      XCTAssertFalse(session.isResponding)
    } catch AppleLocalAISystemError.unavailable(let reason) {
      guard model.availability == before else {
        throw XCTSkip(
          "Native availability changed during admission; rerun to compare the exact reason.")
      }
      guard case .unavailable(let expected) = before else {
        XCTFail("Available model was rejected: \(reason)")
        return
      }
      XCTAssertEqual(reason, expected)
    }
  }

  @MainActor
  func testOptInActualSystemInference() async throws {
    guard ProcessInfo.processInfo.environment["APPLE_LOCAL_AI_SYSTEM_INFERENCE_TESTS"] == "1" else {
      throw XCTSkip("Set APPLE_LOCAL_AI_SYSTEM_INFERENCE_TESTS=1 for actual Apple model inference.")
    }
    guard SystemLanguageModel.default.availability == .available else {
      throw XCTSkip("Apple system model is unavailable; admission checks do not prove inference.")
    }
    let model = SystemModelSampleModel()
    model.startVerification()
    await model.waitUntilIdle()
    let report = try XCTUnwrap(model.report)
    guard report.outcome == "INFERENCE_PASS" else {
      XCTFail("\(report.outcome): \(report.error ?? "No failure details")")
      return
    }
    XCTAssertEqual(report.admission, "ACCEPTED")
    XCTAssertEqual(
      report.checks.map(\.name),
      [
        "admission", "respond", "transcript-after-respond", "stream", "cancel-and-settle",
        "reuse-after-cancel", "native-transcript",
      ])
    XCTAssertFalse(try XCTUnwrap(report.response).isEmpty)
    XCTAssertFalse(model.isWorking)
    XCTAssertFalse(model.isNativeResponding)
    XCTAssertNil(model.errorMessage)
  }
}
