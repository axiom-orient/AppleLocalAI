/// Pure request-admission policy. Native availability stays with the model;
/// this value never caches availability or claims that inference succeeded.
public enum AppleLocalAIModelReadiness: String, Equatable, Sendable {
  case ready
  case unavailable
  case contextUnavailable
  case unsupportedLocale

  public static func evaluate(
    isAvailable: Bool,
    contextSize: Int,
    supportsLocale: Bool
  ) -> Self {
    guard isAvailable else { return .unavailable }
    guard contextSize > 0 else { return .contextUnavailable }
    guard supportsLocale else { return .unsupportedLocale }
    return .ready
  }
}
