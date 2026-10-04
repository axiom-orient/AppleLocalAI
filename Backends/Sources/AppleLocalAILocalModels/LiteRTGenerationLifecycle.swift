import Foundation
import Synchronization

enum LiteRTEngineUseError: Error, Equatable, Sendable {
  case draining
}

/// Small state machine kept separate from the actor so the release contract
/// can be tested without constructing a native Engine or loading model data.
struct LiteRTEngineUseState: Equatable, Sendable {
  private(set) var activeUses = 0
  private(set) var isDraining = false

  mutating func acquire() throws {
    guard !isDraining else { throw LiteRTEngineUseError.draining }
    activeUses += 1
  }

  mutating func beginDraining() {
    isDraining = true
  }

  mutating func release() -> Bool {
    precondition(activeUses > 0, "LiteRT engine use release is unbalanced")
    activeUses -= 1
    return activeUses == 0
  }

  var isSettled: Bool { activeUses == 0 }
}

/// A failed stream consumer must stop native work even when its Task remains
/// active. Task cancellation also stops native work while awaiting a chunk.
enum LiteRTGenerationLifecycle {
  static func run(
    operation: () async throws -> Void,
    cancel: @escaping @Sendable () -> Void
  ) async throws {
    let cancelled = Mutex(false)
    let cancelOnce: @Sendable () -> Void = {
      let shouldCancel = cancelled.withLock { wasCancelled in
        guard !wasCancelled else { return false }
        wasCancelled = true
        return true
      }
      if shouldCancel { cancel() }
    }
    try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        try await operation()
        try Task.checkCancellation()
      } catch {
        cancelOnce()
        throw error
      }
    } onCancel: {
      cancelOnce()
    }
  }
}

struct LiteRTResponseBuffer {
  private var textParts = [String]()
  private var byteCount = 0
  let maximumBytes: Int

  var text: String { textParts.joined() }

  func requireNonEmptyResponse() throws {
    guard byteCount > 0 else {
      throw LiteRTFMError.unsupported("LiteRT returned an empty response")
    }
  }

  init(maximumBytes: Int) throws {
    guard maximumBytes >= 0 else {
      throw LiteRTFMError.unsupported("Buffered LiteRT output limit must not be negative")
    }
    self.maximumBytes = maximumBytes
  }

  mutating func append(_ delta: String) throws {
    try reserve(delta, retain: true, message: "Buffered LiteRT output exceeded its byte limit")
  }

  mutating func record(_ delta: String) throws {
    try reserve(delta, retain: false, message: "LiteRT output exceeded its byte limit")
  }

  private mutating func reserve(_ delta: String, retain: Bool, message: String) throws {
    let deltaBytes = delta.utf8.count
    guard deltaBytes <= maximumBytes - byteCount else {
      throw LiteRTFMError.unsupported(message)
    }
    if retain, !delta.isEmpty { textParts.append(delta) }
    byteCount += deltaBytes
  }
}
