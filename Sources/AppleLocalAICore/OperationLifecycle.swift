import Foundation

public struct OperationID: Equatable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

/// The only owner of request execution phase.
///
/// A result is allowed to mutate runtime state only when its operation ID matches
/// the currently active operation. Cancellation remains active until the native
/// effect settles; starting a replacement request before settlement is rejected.
public enum OperationLifecycle: Equatable, Sendable {
  case idle
  case running(OperationID)
  case cancelling(OperationID)

  public init() {
    self = .idle
  }

  public enum TransitionError: Error, Equatable, Sendable {
    case operationAlreadyActive
    case operationMismatch
    case invalidPhase
  }

  public var operation: OperationID? {
    switch self {
    case .idle:
      nil
    case .running(let operation), .cancelling(let operation):
      operation
    }
  }

  public var isBusy: Bool {
    if case .idle = self { return false }
    return true
  }

  public mutating func start(_ operation: OperationID) throws {
    guard case .idle = self else { throw TransitionError.operationAlreadyActive }
    self = .running(operation)
  }

  public mutating func requestCancellation(_ operation: OperationID) throws {
    guard case .running(let current) = self else { throw TransitionError.invalidPhase }
    guard current == operation else { throw TransitionError.operationMismatch }
    self = .cancelling(operation)
  }

  public mutating func finish(_ operation: OperationID) throws {
    guard case .running(let current) = self else { throw TransitionError.invalidPhase }
    guard current == operation else { throw TransitionError.operationMismatch }
    self = .idle
  }

  public mutating func settleCancellation(_ operation: OperationID) throws {
    guard case .cancelling(let current) = self else { throw TransitionError.invalidPhase }
    guard current == operation else { throw TransitionError.operationMismatch }
    self = .idle
  }
}
