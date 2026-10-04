import Foundation

/// Product policy only. Models, sessions, history and caches remain upstream-owned.
public enum ModelWorkload: String, CaseIterable, Codable, Sendable {
  case automaticLocal
  case fastLocal
  case deepReasoning
  case offlineCustom
  case visionTools
  case manual
}

public enum ModelRequirement: String, CaseIterable, Codable, Sendable {
  case vision, guidedGeneration, reasoning, toolCalling
}

public enum ModelLocation: Sendable {
  case system, customLocal, experimentalLocal, privateCloud, externalServer
}

public struct ModelCandidate<ID: Hashable & Sendable>: Sendable {
  public let id: ID
  public let location: ModelLocation
  public let available: Bool
  public let capabilities: Set<ModelRequirement>

  public init(
    id: ID, location: ModelLocation, available: Bool, capabilities: Set<ModelRequirement>
  ) {
    self.id = id
    self.location = location
    self.available = available
    self.capabilities = capabilities
  }
}

public struct ModelSelection<ID: Hashable & Sendable>: Sendable {
  public let id: ID
  public let reason: String
  public let capabilities: Set<ModelRequirement>
}

public enum ModelSelectionError: LocalizedError, Equatable, Sendable {
  case noEligibleModel

  public var errorDescription: String? {
    "작업 요구사항과 사용 허가를 만족하는 모델이 없습니다. 모델 준비 상태와 capability, PCC 허용을 확인하세요."
  }
}

public enum ModelSelectionPolicy {
  /// Candidate order is product preference, never a fallback after inference failure.
  /// PCC and external servers are excluded from automatic local routing.
  public static func select<ID>(
    workload: ModelWorkload,
    requirements: Set<ModelRequirement>,
    candidates: [ModelCandidate<ID>],
    allowPrivateCloud: Bool,
    manualSelection: ID? = nil
  ) throws -> ModelSelection<ID> {
    var required = requirements
    if workload == .deepReasoning { required.insert(.reasoning) }
    let candidate = candidates.first { candidate in
      guard candidate.available, required.isSubset(of: candidate.capabilities) else { return false }
      if candidate.location == .privateCloud && !allowPrivateCloud { return false }
      switch workload {
      case .automaticLocal, .visionTools:
        return [.system, .customLocal, .experimentalLocal].contains(candidate.location)
      case .fastLocal:
        return candidate.location == .system
      case .deepReasoning:
        return candidate.location != .externalServer
      case .offlineCustom:
        return candidate.location == .customLocal
      case .manual:
        return candidate.id == manualSelection
      }
    }
    guard let candidate else { throw ModelSelectionError.noEligibleModel }
    let capabilities = required.map(\.rawValue).sorted().joined(separator: ", ")
    return ModelSelection(
      id: candidate.id,
      reason: "\(workload.rawValue) · \(capabilities.isEmpty ? "text" : capabilities) · 승인된 모델",
      capabilities: candidate.capabilities
    )
  }
}
