import Foundation

/// Request admission and runtime readiness, separate from a model's feature capabilities.
///
/// `configured` means the app's local declaration is valid. It does not imply
/// that an external server is running; the first request remains the authority
/// for that runtime fact.
public enum LocalAIProviderReadiness: Equatable, Sendable {
  /// Runtime facts are still being loaded. A request must not be admitted yet.
  case checking
  case ready
  case configured
  case unavailable
  case quotaExceeded
  case unsupportedLocale
  case invalidConfiguration

  public var canSend: Bool {
    switch self {
    case .ready, .configured:
      return true
    case .checking, .unavailable, .quotaExceeded, .unsupportedLocale, .invalidConfiguration:
      return false
    }
  }

  public var isConfigurationValid: Bool {
    switch self {
    case .invalidConfiguration:
      return false
    case .checking, .ready, .configured, .unavailable, .quotaExceeded, .unsupportedLocale:
      return true
    }
  }
}
