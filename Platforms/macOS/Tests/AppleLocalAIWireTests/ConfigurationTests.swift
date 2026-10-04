import Foundation
import Testing

@testable import AppleLocalAIWire

@Suite struct ConfigurationTests {
  private var base: ProviderConfiguration {
    .init(
      port: 8765, tokenEnvironment: "LOCAL_AI_TOKEN", allowPrivateCloud: false,
      allowExternalNetwork: false, profiles: [.init(id: "apple", backend: .system)])
  }
  @Test func defaultConfigAndSecretPolicy() throws {
    let config = base
    try config.validate()
    #expect(throws: (any Error).self) { try config.token(environment: [:]) }
    #expect(throws: (any Error).self) { try config.token(environment: ["LOCAL_AI_TOKEN": "short"]) }
    let token = String(repeating: "secret", count: 8)
    #expect(try config.token(environment: ["LOCAL_AI_TOKEN": token]) == token)
    #expect(ProviderConfiguration.tokensEqual(token, token))
    #expect(!ProviderConfiguration.tokensEqual(token, token + "x"))
    #expect(!ProviderConfiguration.tokensEqual(token, "x" + token.dropFirst()))
  }
  @Test func consentIsSeparateFromProfileExistence() throws {
    var config = base
    config.profiles = [.init(id: "pcc", backend: .privateCloud)]
    #expect(throws: (any Error).self) { try config.validate() }
    config.allowPrivateCloud = true
    try config.validate()
  }
  @Test func cloudEndpointRequiresHTTPSAndExplicitPermission() throws {
    var config = base
    config.profiles = [
      .init(
        id: "remote", backend: .chatCompletions, resource: "https://api.example.com/v1",
        remoteModel: "model", capabilities: [])
    ]
    #expect(throws: (any Error).self) { try config.validate() }
    config.allowExternalNetwork = true
    try config.validate()
    config.profiles[0].resource = "http://api.example.com/v1"
    #expect(throws: (any Error).self) { try config.validate() }
  }
  @Test func localServerCannotRecurseOrEmbedCredentials() throws {
    var config = base
    config.profiles = [
      .init(
        id: "remote", backend: .chatCompletions, resource: "http://127.0.0.1:8765/v1",
        remoteModel: "m", capabilities: [])
    ]
    #expect(throws: (any Error).self) { try config.validate() }
    config.profiles[0].resource = "http://127.0.0.1:8080/v1"
    try config.validate()
    config.profiles[0].resource = "http://u:p@127.0.0.1:8080/v1"
    #expect(throws: (any Error).self) { try config.validate() }
    config.profiles[0].resource = "http://127.0.0.1:8080/v1/chat/completions"
    #expect(throws: (any Error).self) { try config.validate() }
  }
  @Test func localhostLoopbackEndpointUsesTheSamePolicyAsSharedRemoteConfiguration() throws {
    var config = base
    config.profiles = [
      .init(
        id: "remote", backend: .chatCompletions, resource: "http://localhost:8080/v1",
        remoteModel: "m", capabilities: [])
    ]

    try config.validate()
  }
  @Test func idsPathsCapabilitiesAndOwnershipAreValidated() throws {
    var config = base
    config.profiles += config.profiles
    #expect(throws: (any Error).self) { try config.validate() }
    config = base
    config.profiles[0].id = "auto-local"
    #expect(throws: (any Error).self) { try config.validate() }
    config = base
    config.profiles[0].remoteModel = "unexpected"
    #expect(throws: (any Error).self) { try config.validate() }
    config = base
    config.profiles = [.init(id: "mlx", backend: .mlx, resource: "relative")]
    #expect(throws: (any Error).self) { try config.validate() }
    config.profiles[0].resource = "/models/a"
    #expect(throws: (any Error).self) { try config.validate() }
    config.profiles[0].capabilities = []
    try config.validate()
    config.profiles[0].capabilities = [.vision]
    #expect(throws: (any Error).self) { try config.validate() }
  }
  @Test func decodeRejectsUnknownField() {
    let data = Data(
      #"{"port":8765,"tokenEnvironment":"TOKEN","allowPrivateCloud":false,"allowExternalNetwork":false,"profiles":[{"id":"a","backend":"system"}],"unrecognizedField":true}"#
        .utf8)
    #expect(throws: (any Error).self) { try ProviderConfiguration.decode(data) }
  }
  @Test func decodeRejectsOversizedConfiguration() {
    let data = Data(repeating: 0x20, count: ProviderConfiguration.maximumConfigurationBytes + 1)
    #expect(throws: (any Error).self) { try ProviderConfiguration.decode(data) }
  }
  @Test(arguments: [
    "9223372036854775807", "-9223372036854775808", "18446744073709551615", "9007199254740993",
    "1.25", "true", "null", #"{"array":[1,2,3],"k":"값"}"#,
  ])
  func jsonRoundTrip(_ json: String) throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    let encoded = try value.jsonString()
    #expect(encoded == json)
    #expect(try JSONDecoder().decode(JSONValue.self, from: value.encoded()) == value)
  }
  @Test func integerRangeIsSafe() throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data("18446744073709551615".utf8))
    #expect(value.integer == nil)
    #expect(JSONValue.number(Double.infinity).integer == nil)
    #expect(JSONValue.number(1.1).integer == nil)
  }
  @Test func deeplyNestedJSONIsRejectedBeforeExpansion() {
    let depth = JSONValue.maximumNestingDepth + 1
    let json = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
  }
}

@Suite struct RemoteEndpointRegressionTests {
  @Test(arguments: [
    "http://127.0.0.1:9000/v1/chat/completions/",
    "http://127.0.0.1:9000/v1/RESPONSES/",
    "http://127.0.0.1:0/v1",
    "http://127.0.0.1:65536/v1",
  ]) func invalidBaseURLIsRejected(_ endpoint: String) {
    let config = ProviderConfiguration(
      port: 8765, tokenEnvironment: "TOKEN", allowPrivateCloud: false,
      allowExternalNetwork: false,
      profiles: [
        .init(
          id: "upstream", backend: .chatCompletions, resource: endpoint,
          remoteModel: "model", capabilities: [])
      ])
    #expect(throws: (any Error).self) { try config.validate() }
  }

  @Test func blankModelIsRejected() {
    let config = ProviderConfiguration(
      port: 8765, tokenEnvironment: "TOKEN", allowPrivateCloud: false,
      allowExternalNetwork: false,
      profiles: [
        .init(
          id: "upstream", backend: .chatCompletions,
          resource: "http://127.0.0.1:9000/v1", remoteModel: " \n ", capabilities: [])
      ])
    #expect(throws: (any Error).self) { try config.validate() }
  }
}
