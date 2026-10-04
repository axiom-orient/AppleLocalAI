import AppleLocalAIHost
import Foundation

package enum ProviderBackend: String, Codable, Sendable, CaseIterable {
  case system, privateCloud, coreAI, mlx, liteRT, chatCompletions
  package var location: ModelLocation {
    switch self {
    case .system: .system
    case .privateCloud: .privateCloud
    case .coreAI, .mlx, .liteRT: .customLocal
    case .chatCompletions: .externalServer
    }
  }
}

/// Inference policy is configuration; credentials and session history are not stored here.
package struct ProviderProfile: Codable, Equatable, Sendable {
  package var id: String
  package var backend: ProviderBackend
  package var resource: String?
  package var remoteModel: String?
  package var instructions: String?
  package var historyWindow: Int?
  package var reasoning: String?
  package var capabilities: Set<ModelRequirement>?
  package var credentialEnvironment: String?
  package var backendDevice: String?

  package init(
    id: String, backend: ProviderBackend, resource: String? = nil,
    remoteModel: String? = nil, instructions: String? = nil, historyWindow: Int? = nil,
    reasoning: String? = nil, capabilities: Set<ModelRequirement>? = nil,
    credentialEnvironment: String? = nil, backendDevice: String? = nil
  ) {
    self.id = id
    self.backend = backend
    self.resource = resource
    self.remoteModel = remoteModel
    self.instructions = instructions
    self.historyWindow = historyWindow
    self.reasoning = reasoning
    self.capabilities = capabilities
    self.credentialEnvironment = credentialEnvironment
    self.backendDevice = backendDevice
  }
}

package struct ProviderConfiguration: Codable, Equatable, Sendable {
  package var port: Int
  package var tokenEnvironment: String
  package var allowPrivateCloud: Bool
  package var allowExternalNetwork: Bool
  package var profiles: [ProviderProfile]

  package static let maximumProfiles = 64
  package static let maximumProfileIDLength = 128
  package static let maximumConfigurationBytes = 4 * 1024 * 1024
  package static let minimumTokenBytes = 24
  package static let maximumTokenBytes = 256
  package static let maximumResponseTokens = 1_048_576
  package static let maximumBodyBytes = 1_048_576
  package static let maximumOutputBytes = 4_194_304
  package static let maximumToolArgumentsBytes = 1_048_576
  package static let maximumToolCount = 128
  package static let maximumHistoryEntries = 4_096
  package static let maximumConnections = 16
  package static let requestTimeoutSeconds = 300
  package static let headerTimeoutSeconds = 15
  package static let taskAliases: [String: ModelWorkload] = [
    "auto-local": .automaticLocal, "fast-local": .fastLocal,
    "deep-reasoning": .deepReasoning, "offline-custom": .offlineCustom,
  ]

  package static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumConfigurationBytes else {
      throw WireError.invalid("Configuration exceeds the 4 MiB limit")
    }
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    try root.allowingOnly([
      "port", "tokenEnvironment", "allowPrivateCloud", "allowExternalNetwork", "profiles",
    ])
    for p in root["profiles"]?.array ?? [] {
      try p.allowingOnly([
        "id", "backend", "resource", "remoteModel", "instructions", "historyWindow", "reasoning",
        "capabilities", "credentialEnvironment", "backendDevice",
      ])
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate()
    return value
  }

  package func validate() throws {
    guard (1024...65535).contains(port) else {
      throw WireError.invalid("port must be in 1024...65535")
    }
    guard !tokenEnvironment.isEmpty,
      tokenEnvironment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    else {
      throw WireError.invalid("Invalid tokenEnvironment")
    }
    guard !profiles.isEmpty, profiles.count <= Self.maximumProfiles else {
      throw WireError.invalid("Configure 1...64 model profiles")
    }
    var ids = Set<String>()
    for profile in profiles {
      guard !profile.id.isEmpty, profile.id.count <= Self.maximumProfileIDLength,
        profile.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
        Self.taskAliases[profile.id] == nil, ids.insert(profile.id).inserted
      else {
        throw WireError.invalid("Invalid, reserved, or duplicate profile id: \(profile.id)")
      }
      if profile.backend != .chatCompletions,
        profile.remoteModel != nil || profile.credentialEnvironment != nil
      {
        throw WireError.invalid(
          "remoteModel and credentialEnvironment belong to external profiles only")
      }
      if profile.capabilities?.contains(.vision) == true {
        throw WireError.unsupported(
          "This HTTP provider admits text/function input only; do not advertise vision")
      }
      if let window = profile.historyWindow, !(1...Self.maximumHistoryEntries).contains(window) {
        throw WireError.invalid("historyWindow outside limits")
      }
      if let reasoning = profile.reasoning, !["none", "low", "medium", "high"].contains(reasoning) {
        throw WireError.invalid("reasoning supports none/low/medium/high")
      }
      if profile.backend == .privateCloud, !allowPrivateCloud {
        throw WireError.invalid("PCC profile requires explicit allowPrivateCloud")
      }
      switch profile.backend {
      case .coreAI, .mlx, .liteRT:
        guard let path = profile.resource, path.hasPrefix("/"), !path.contains("\0") else {
          throw WireError.invalid("Local resource must be an absolute user-configured path")
        }
      case .chatCompletions:
        guard let endpoint = profile.resource, let name = profile.remoteModel else {
          throw WireError.invalid("Configured upstream requires resource and remoteModel")
        }
        let remote: RemoteLanguageModelConfiguration
        do {
          remote = try RemoteLanguageModelConfiguration(endpointString: endpoint, modelName: name)
        } catch {
          throw WireError.invalid(error.localizedDescription)
        }
        let url = remote.endpoint
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased()
        let loopback = ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)
        if loopback && (url.port ?? (scheme == "https" ? 443 : 80)) == port {
          throw WireError.invalid(
            "An upstream profile must not point to this provider's listening port")
        }
        guard loopback || (allowExternalNetwork && scheme == "https") else {
          throw WireError.invalid("Non-loopback model requires allowExternalNetwork and HTTPS")
        }
        if let key = profile.credentialEnvironment,
          key.isEmpty
            || !key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        {
          throw WireError.invalid("Invalid credential environment name")
        }
      case .system, .privateCloud:
        if profile.resource != nil {
          throw WireError.invalid("System/PCC profiles do not take model paths")
        }
      }
      if let device = profile.backendDevice,
        profile.backend != .liteRT || !["cpu", "gpu"].contains(device)
      {
        throw WireError.invalid("backendDevice is cpu/gpu for LiteRT only")
      }
      if [.mlx, .chatCompletions].contains(profile.backend), profile.capabilities == nil {
        throw WireError.invalid(
          "MLX/external models require explicit verified capabilities; use [] for text only")
      }
    }
  }

  package func token(environment: [String: String]) throws -> String {
    guard let token = environment[tokenEnvironment], token.utf8.count >= Self.minimumTokenBytes,
      token.utf8.count <= Self.maximumTokenBytes,
      token.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
    else {
      throw WireError.invalid(
        "Set \(tokenEnvironment) to a secret of 24...256 printable ASCII characters")
    }
    return token
  }

  package static func tokensEqual(_ expected: String, _ actual: String) -> Bool {
    let a = Array(expected.utf8)
    let b = Array(actual.utf8)
    var difference = a.count ^ b.count
    for index in 0..<max(a.count, b.count) {
      difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
    }
    return difference == 0
  }
}
