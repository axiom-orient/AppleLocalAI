import AppleLocalAICore
import Foundation

/// One native operation's admission, cancellation and settlement owner.
/// Stores no model, profile, transcript or UI state. Keeping this concrete
/// effect boundary independent of Foundation Models makes its actual Task
/// semantics testable without an SDK substitute or a second session engine.
@MainActor
final class SessionOperation {
  private(set) var lifecycle: OperationLifecycle = .idle
  private var cancelActiveEffect: (@Sendable () -> Void)?

  var isBusy: Bool { lifecycle.isBusy }

  func cancel() {
    guard case .running(let operation) = lifecycle else { return }
    do {
      try lifecycle.requestCancellation(operation)
      cancelActiveEffect?()
    } catch {
      assertionFailure("Invalid cancellation transition: \(error)")
    }
  }

  func run<Value: Sendable>(
    settleEffect: (@MainActor () async throws -> Void)? = nil,
    _ effect: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    guard !Task.isCancelled else { throw AppleLocalAIError.cancelled }
    let operation = OperationID()
    do {
      try lifecycle.start(operation)
    } catch {
      throw AppleLocalAIError.operationInProgress
    }
    defer { settle(operation) }

    let task = Task { @MainActor in
      // Cancellation can arrive after admission but before this child runs.
      // A cancellation handler cancels a Task; it does not skip its body.
      try Task.checkCancellation()
      let value = try await effect()
      // A child may cancel itself without cancelling its awaiting parent.
      try Task.checkCancellation()
      return value
    }
    cancelActiveEffect = { task.cancel() }

    do {
      let terminal = await withTaskCancellationHandler {
        await task.result
      } onCancel: {
        task.cancel()
      }
      if let settleEffect {
        // Native producers can outlive a cancelled iterator. This owned cleanup
        // task does not inherit caller cancellation and is joined before idle.
        let settlement = Task { @MainActor in try await settleEffect() }
        try await settlement.value
      }
      let value = try terminal.get()

      if lifecycle == .cancelling(operation) || Task.isCancelled {
        throw AppleLocalAIError.cancelled
      }
      return value
    } catch {
      let wasCancelling =
        lifecycle == .cancelling(operation)
        || Task.isCancelled || error is CancellationError
      if wasCancelling { throw AppleLocalAIError.cancelled }
      throw error
    }
  }

  private func settle(_ operation: OperationID) {
    defer { cancelActiveEffect = nil }
    do {
      switch lifecycle {
      case .running:
        try lifecycle.finish(operation)
      case .cancelling:
        try lifecycle.settleCancellation(operation)
      case .idle:
        assertionFailure("Operation settled after lifecycle became idle")
      }
    } catch {
      assertionFailure("Invalid operation settlement: \(error)")
    }
  }
}
