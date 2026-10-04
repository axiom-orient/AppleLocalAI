import AppleLocalAICore
import Foundation
import Testing

@testable import AppleLocalAI

/// Exercises the same concrete Task owner used by AppleLocalAISession. These
/// tests require no Foundation Models substitute, weights or timing sleeps.
@Suite("Native operation execution")
@MainActor
struct OperationExecutionTests {
  @Test("A previously cancelled caller cannot invoke the effect")
  func cancellationBeforeAdmission() async {
    let operation = SessionOperation()
    var invoked = false
    let caller = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await operation.run {
        invoked = true
        return "unexpected"
      }
    }
    await #expect(throws: AppleLocalAIError.cancelled) { try await caller.value }
    #expect(!invoked)
    #expect(operation.lifecycle == .idle)
  }

  @Test("Explicit cancellation stays busy until an uncooperative effect settles")
  func cancellationWaitsForSettlement() async throws {
    let operation = SessionOperation()
    let effect = SuspendedOperationEffect()
    operation.cancel()
    #expect(operation.lifecycle == .idle)
    let caller = Task { try await operation.run { await effect.run() } }
    await effect.waitUntilStarted()
    let identity = try #require(operation.lifecycle.operation)

    operation.cancel()
    operation.cancel()
    #expect(operation.lifecycle == .cancelling(identity))
    #expect(operation.isBusy)
    await #expect(throws: AppleLocalAIError.operationInProgress) {
      try await operation.run { "replacement" }
    }
    #expect(operation.lifecycle == .cancelling(identity))

    effect.release()
    await #expect(throws: AppleLocalAIError.cancelled) { try await caller.value }
    #expect(effect.observedCancellation)
    #expect(operation.lifecycle == .idle)
    #expect(try await operation.run { "next" } == "next")
  }

  @Test("Parent cancellation propagates and rejects a late success")
  func parentCancellation() async throws {
    let operation = SessionOperation()
    let effect = SuspendedOperationEffect()
    let caller = Task { try await operation.run { await effect.run() } }
    await effect.waitUntilStarted()
    caller.cancel()
    #expect(operation.isBusy)
    effect.release()
    await #expect(throws: AppleLocalAIError.cancelled) { try await caller.value }
    #expect(effect.observedCancellation)
    #expect(operation.lifecycle == .idle)
    #expect(try await operation.run { 7 } == 7)
  }

  @Test("Native failure retains its error and releases admission once")
  func failureAndRecovery() async throws {
    let operation = SessionOperation()
    await #expect(throws: ProbeError.failed) {
      try await operation.run { () async throws -> String in throw ProbeError.failed }
    }
    #expect(operation.lifecycle == .idle)
    #expect(try await operation.run { "recovered" } == "recovered")
  }

  @Test("Native cancellation is normalized without leaving a busy operation")
  func nativeCancellationAndRecovery() async throws {
    let operation = SessionOperation()
    await #expect(throws: AppleLocalAIError.cancelled) {
      try await operation.run { () async throws -> String in throw CancellationError() }
    }
    #expect(operation.lifecycle == .idle)
    #expect(try await operation.run { "recovered" } == "recovered")
  }

  @Test("Rejected concurrent admission cannot settle the running operation")
  func concurrentAdmissionKeepsIdentity() async throws {
    let operation = SessionOperation()
    let effect = SuspendedOperationEffect()
    let caller = Task { try await operation.run { await effect.run() } }
    await effect.waitUntilStarted()
    let identity = try #require(operation.lifecycle.operation)
    await #expect(throws: AppleLocalAIError.operationInProgress) {
      try await operation.run { "replacement" }
    }
    #expect(operation.lifecycle == .running(identity))
    effect.release()
    #expect(try await caller.value == "settled")
    #expect(!effect.observedCancellation)
    #expect(operation.lifecycle == .idle)
  }

  @Test("Cancellation requested by the effect itself cannot publish success")
  func cancellationInsideEffect() async throws {
    let operation = SessionOperation()
    await #expect(throws: AppleLocalAIError.cancelled) {
      try await operation.run {
        operation.cancel()
        #expect(Task.isCancelled)
        return "late success"
      }
    }
    #expect(operation.lifecycle == .idle)
    #expect(try await operation.run { "next" } == "next")
  }

  @Test("A self-cancelled child effect cannot return success to an uncancelled caller")
  func cancelledChildCannotReportSuccess() async throws {
    let operation = SessionOperation()
    await #expect(throws: AppleLocalAIError.cancelled) {
      try await operation.run {
        withUnsafeCurrentTask { $0?.cancel() }
        return "late success"
      }
    }
    #expect(!Task.isCancelled)
    #expect(operation.lifecycle == .idle)
    #expect(try await operation.run { "next" } == "next")
  }

  @Test("Cancelling an already settled caller cannot cancel the next operation")
  func staleCallerCancellationDoesNotReachReplacement() async throws {
    let operation = SessionOperation()
    let first = Task { try await operation.run { "first" } }
    #expect(try await first.value == "first")
    let effect = SuspendedOperationEffect()
    let second = Task { try await operation.run { await effect.run() } }
    await effect.waitUntilStarted()
    let identity = try #require(operation.lifecycle.operation)
    first.cancel()
    #expect(operation.lifecycle == .running(identity))
    effect.release()
    #expect(try await second.value == "settled")
    #expect(!effect.observedCancellation)
    #expect(operation.lifecycle == .idle)
  }

  @Test("Native settlement keeps admission until cleanup is joined", arguments: [false, true])
  func nativeSettlementBarrier(cancelled: Bool) async throws {
    let operation = SessionOperation()
    let cleanup = SuspendedOperationEffect()
    let caller = Task {
      try await operation.run(settleEffect: {
        _ = await cleanup.run()
      }) { "completed" }
    }
    await cleanup.waitUntilStarted()
    if cancelled {
      caller.cancel()
      operation.cancel()
    }
    #expect(operation.isBusy)
    await #expect(throws: AppleLocalAIError.operationInProgress) {
      try await operation.run { "premature reuse" }
    }
    cleanup.release()
    if cancelled {
      await #expect(throws: AppleLocalAIError.cancelled) { try await caller.value }
    } else {
      #expect(try await caller.value == "completed")
    }
    #expect(!cleanup.observedCancellation)
    #expect(operation.lifecycle == .idle)
    #expect(
      try await operation.run { "reuse after native settlement" } == "reuse after native settlement"
    )
  }

  @Test("An already cancelled caller joins uncancelled native cleanup")
  func cancellationBeforeNativeCleanup() async throws {
    let operation = SessionOperation()
    let nativeEffect = SuspendedOperationEffect()
    let cleanup = SuspendedOperationEffect()
    let caller = Task {
      try await operation.run(settleEffect: {
        _ = await cleanup.run()
      }) { await nativeEffect.run() }
    }
    await nativeEffect.waitUntilStarted()
    caller.cancel()
    operation.cancel()
    nativeEffect.release()
    await cleanup.waitUntilStarted()
    #expect(operation.isBusy)
    cleanup.release()
    await #expect(throws: AppleLocalAIError.cancelled) { try await caller.value }
    #expect(nativeEffect.observedCancellation)
    #expect(!cleanup.observedCancellation)
    #expect(operation.lifecycle == .idle)
  }
}

private enum ProbeError: Error { case failed }

@MainActor
private final class SuspendedOperationEffect {
  private var continuation: CheckedContinuation<String, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var started = false
  private(set) var observedCancellation = false

  func run() async -> String {
    let value = await withCheckedContinuation { continuation in
      self.continuation = continuation
      started = true
      startWaiter?.resume()
      startWaiter = nil
    }
    observedCancellation = Task.isCancelled
    return value
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func release() {
    continuation?.resume(returning: "settled")
    continuation = nil
  }
}
