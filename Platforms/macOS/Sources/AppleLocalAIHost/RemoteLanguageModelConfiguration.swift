import Foundation

/// Validated configuration for an explicitly selected remote LanguageModel backend.
///
/// The configuration owns only endpoint/model identity. Transport, inference,
/// session history, tools, and generation remain owned by Foundation Models and
/// the selected `LanguageModel` conformer.
public struct RemoteLanguageModelConfiguration: Equatable, Sendable {
  public static let endpointEnvironmentKey = "APPLELOCALAI_REMOTE_URL"
  public static let modelEnvironmentKey = "APPLELOCALAI_REMOTE_MODEL"
  public static let apiKeyEnvironmentKey = "APPLELOCALAI_REMOTE_API_KEY"

  public let endpoint: URL
  public let modelName: String

  public init(endpointString: String, modelName: String) throws {
    guard let endpoint = Self.endpointURL(from: endpointString) else {
      throw RemoteLanguageModelConfigurationError.invalidEndpoint
    }
    let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedModelName.isEmpty else {
      throw RemoteLanguageModelConfigurationError.invalidModelName
    }
    self.endpoint = endpoint
    self.modelName = normalizedModelName
  }

  public static func endpointURL(from endpointString: String) -> URL? {
    let raw = endpointString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: raw),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      ["http", "https"].contains(scheme),
      components.port.map({ (1...65535).contains($0) }) ?? true,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let endpoint = components.url
    else { return nil }

    let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    guard scheme == "https" || loopback else { return nil }

    let normalizedPath = components.path.lowercased().trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    let terminalEndpoints = ["chat/completions", "responses", "messages"]
    guard !terminalEndpoints.contains(where: { normalizedPath.hasSuffix($0) }) else { return nil }
    return endpoint
  }
}

public enum RemoteLanguageModelConfigurationError: Error, LocalizedError, Sendable, Equatable {
  case invalidEndpoint
  case invalidModelName

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return
        "Use an HTTPS base URL, or HTTP only for a loopback endpoint. Supply a base URL rather than a concrete completion/messages endpoint."
    case .invalidModelName:
      return "Enter the model identifier expected by the remote LanguageModel backend."
    }
  }
}
