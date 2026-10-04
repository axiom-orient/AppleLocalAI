#if os(macOS)

  import Foundation

  enum AppleLocalAIModelError: LocalizedError {
    case appleIntelligenceUnavailable
    case privateCloudUnavailable
    case privateCloudQuotaExceeded
    case unsupportedLocale
    case unsupportedCapability(String)
    case invalidGenerationSchema(String)
    case emptyResponse

    var errorDescription: String? {
      switch self {
      case .appleIntelligenceUnavailable:
        return "Apple Intelligence is not available on this Mac."
      case .privateCloudUnavailable:
        return "Private Cloud Compute is not available for this request."
      case .privateCloudQuotaExceeded:
        return "Private Cloud Compute quota has been reached."
      case .unsupportedLocale:
        return "The current locale is not supported by Apple Intelligence."
      case .unsupportedCapability(let capability):
        return "The selected Foundation Models capability is unavailable: \(capability)."
      case .invalidGenerationSchema(let message):
        return "The Foundation Models generation schema is invalid: \(message)"
      case .emptyResponse:
        return "The local provider returned an empty response."
      }
    }
  }

#endif
