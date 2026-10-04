import Foundation

public enum LiteRTProviderBackendChoice: String, CaseIterable, Codable, Equatable, Sendable {
  case cpu
  case gpu

  public var title: String {
    switch self {
    case .cpu: "CPU"
    case .gpu: "GPU"
    }
  }
}

public enum LiteRTProviderVisionBackendChoice: String, CaseIterable, Codable, Equatable, Sendable {
  case disabled
  case cpu
  case gpu

  public var title: String {
    switch self {
    case .disabled: "사용 안 함"
    case .cpu: "CPU"
    case .gpu: "GPU"
    }
  }
}

public struct LiteRTProviderSettings: Codable, Equatable, Sendable {
  public var modelPath: String
  public var backend: LiteRTProviderBackendChoice
  public var visionBackend: LiteRTProviderVisionBackendChoice

  private enum CodingKeys: String, CodingKey {
    case modelPath
    case backend
    case visionBackend
  }

  public static let standard = Self(modelPath: "", backend: .gpu, visionBackend: .disabled)

  public init(
    modelPath: String,
    backend: LiteRTProviderBackendChoice,
    visionBackend: LiteRTProviderVisionBackendChoice = .disabled
  ) {
    self.modelPath = modelPath
    self.backend = backend
    self.visionBackend = visionBackend
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    modelPath = try container.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
    backend =
      try container.decodeIfPresent(LiteRTProviderBackendChoice.self, forKey: .backend) ?? .gpu
    visionBackend =
      try container.decodeIfPresent(
        LiteRTProviderVisionBackendChoice.self,
        forKey: .visionBackend
      ) ?? .disabled
  }

  public var modelIdentifier: String {
    let path = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return "모델 파일 선택 필요" }
    return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }
}
