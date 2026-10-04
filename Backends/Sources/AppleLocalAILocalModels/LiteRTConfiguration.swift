import Foundation

public enum LiteRTBackendChoice: Sendable {
  case cpu
  case gpu
}

public enum LiteRTVisionBackendChoice: Sendable {
  case disabled
  case cpu
  case gpu
}

public struct LiteRTConfiguration: Sendable {
  public let modelURL: URL
  public let backend: LiteRTBackendChoice
  public let visionBackend: LiteRTVisionBackendChoice

  public init(
    modelURL: URL,
    backend: LiteRTBackendChoice = .gpu,
    visionBackend: LiteRTVisionBackendChoice = .disabled
  ) {
    self.modelURL = modelURL.standardizedFileURL
    self.backend = backend
    self.visionBackend = visionBackend
  }
}

public enum LiteRTConfigurationError: Error, LocalizedError, Sendable {
  case invalidModel
  case invalidCapabilities
  case textUnavailable
  case visionUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidModel:
      "Choose a valid local .litertlm model."
    case .invalidCapabilities:
      "The LiteRT model capabilities could not be read."
    case .textUnavailable:
      "The LiteRT model doesn't contain a compatible text decoder."
    case .visionUnavailable:
      "Vision was requested but the LiteRT model doesn't contain a compatible vision encoder."
    }
  }
}
