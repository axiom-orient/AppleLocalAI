import Testing
@testable import AppleLocalAICore

@Suite("Operation lifecycle")
struct OperationLifecycleTests {
  @Test("Completion requires a running operation")
  func completionRequiresRunningPhase() {
    var state = OperationLifecycle.idle

    #expect(throws: OperationLifecycle.TransitionError.invalidPhase) {
      try state.finish(OperationID())
    }
    #expect(state == .idle)
  }

  @Test("Cancellation stays busy until settlement")
  func cancellationStaysBusyUntilSettlement() throws {
    var state = OperationLifecycle.idle
    let first = OperationID()

    try state.start(first)
    try state.requestCancellation(first)
    #expect(state.isBusy)

    try state.settleCancellation(first)
    #expect(!state.isBusy)
    #expect(state == .idle)
  }

  @Test("Cancellation rejects a replacement before settlement")
  func cancellationRejectsReplacementBeforeSettlement() throws {
    var state = OperationLifecycle.idle
    let first = OperationID()
    let replacement = OperationID()

    try state.start(first)
    try state.requestCancellation(first)

    #expect(throws: OperationLifecycle.TransitionError.operationAlreadyActive) {
      try state.start(replacement)
    }
    #expect(state == .cancelling(first))
  }

  @Test("Stale completion cannot settle a newer operation")
  func staleCompletion() throws {
    var state = OperationLifecycle.idle
    let stale = OperationID()
    let current = OperationID()

    try state.start(stale)
    try state.finish(stale)
    try state.start(current)

    #expect(throws: OperationLifecycle.TransitionError.operationMismatch) {
      try state.finish(stale)
    }
    #expect(state == .running(current))
  }
}
