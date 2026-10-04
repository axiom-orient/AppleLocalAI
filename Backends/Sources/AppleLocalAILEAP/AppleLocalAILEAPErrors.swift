import Foundation

@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAPError: Error, LocalizedError, Sendable {
  case invalidGenerationOptions(String)
  case invalidAudioInput(String)
  case invalidAudioOutput(String)
  case invalidSchema
  case noPrompt
  case invalidRuntimeOutput
  case outputLimitExceeded
  case modelNotPrepared
  case modelBusy
  case invalidArtifactRoot
  case insufficientDisk(requiredBytes: UInt64, availableBytes: UInt64?)
  case invalidArtifact(
    expectedBytes: UInt64, actualBytes: UInt64, expectedSHA256: String, actualSHA256: String)
  case downloadFailed(statusCode: Int?)
  case nativeFailure(String)

  public var errorDescription: String? {
    switch self {
    case .invalidGenerationOptions(let message):
      return message
    case .invalidAudioInput(let message):
      return message
    case .invalidAudioOutput(let message):
      return message
    case .invalidSchema:
      return "The requested Foundation Models schema is not a bounded JSON object."
    case .noPrompt:
      return "The LEAP executor requires a non-empty final user prompt."
    case .invalidRuntimeOutput:
      return "The LEAP runtime completed without a consistent textual response."
    case .outputLimitExceeded:
      return "The LEAP response exceeded its finite output limit."
    case .modelNotPrepared:
      return "The requested LEAP model has not been prepared."
    case .modelBusy:
      return "The LEAP runtime is busy with another operation."
    case .invalidArtifactRoot:
      return "The LEAP artifact root must be an existing local directory, not a symbolic link."
    case .insufficientDisk(let requiredBytes, let availableBytes):
      let available = availableBytes.map(String.init) ?? "unknown"
      return "LEAP needs at least \(requiredBytes) bytes of free storage; available: \(available)."
    case .invalidArtifact:
      return
        "The downloaded LEAP model failed path, regular-file, exact size, or SHA-256 validation."
    case .downloadFailed(let statusCode):
      return "The LEAP model download failed\(statusCode.map { " with HTTP \($0)" } ?? "")."
    case .nativeFailure(let message):
      return "The LEAP native runtime failed: \(message)"
    }
  }
}
