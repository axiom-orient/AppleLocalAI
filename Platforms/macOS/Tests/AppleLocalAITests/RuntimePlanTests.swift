import AppleLocalAIHost
import Testing

@Suite("Local AI routing contract")
struct RuntimePlanTests {
  @Test func nativeFeatureUsesSystemModelOnPhone() throws {
    #expect(
      try LocalAIPlan(platform: .iPhone, workload: .nativeFeature).runtime == .systemFoundationModel
    )
  }

  @Test func nativeFeatureUsesSystemModelOnMac() throws {
    #expect(
      try LocalAIPlan(platform: .mac, workload: .nativeFeature).runtime == .systemFoundationModel)
  }

  @Test func customProductionUsesCoreAI() throws {
    #expect(try LocalAIPlan(platform: .iPhone, workload: .customProductionModel).runtime == .coreAI)
    #expect(try LocalAIPlan(platform: .mac, workload: .customProductionModel).runtime == .coreAI)
  }

  @Test func externalAgentUsesFoundationModelsProviderOnMac() throws {
    #expect(
      try LocalAIPlan(platform: .mac, workload: .externalAgent).runtime == .foundationModelsProvider
    )
    #expect(throws: LocalAIPlanError.externalAgentRequiresMac) {
      try LocalAIPlan(platform: .iPhone, workload: .externalAgent)
    }
  }

  @Test func remoteConfigurationNormalizesExplicitHTTPSBaseURL() throws {
    let configuration = try RemoteLanguageModelConfiguration(
      endpointString: "  https://api.example.com/v1/  ",
      modelName: " model-1 "
    )

    #expect(configuration.endpoint.absoluteString == "https://api.example.com/v1/")
    #expect(configuration.modelName == "model-1")
  }

  @Test func remoteConfigurationAllowsLoopbackHTTPButRejectsInsecureRemote() throws {
    #expect(
      RemoteLanguageModelConfiguration.endpointURL(from: "http://127.0.0.1:8000/v1") != nil)
    #expect(
      RemoteLanguageModelConfiguration.endpointURL(from: "http://localhost:8000/v1") != nil)
    #expect(
      RemoteLanguageModelConfiguration.endpointURL(from: "http://example.com/v1") == nil)
    #expect(
      RemoteLanguageModelConfiguration.endpointURL(
        from: "https://api.example.com/v1/chat/completions") == nil)
  }

  @Test func remoteConfigurationRejectsEmptyModelNames() {
    #expect(throws: RemoteLanguageModelConfigurationError.invalidModelName) {
      try RemoteLanguageModelConfiguration(
        endpointString: "https://api.example.com/v1",
        modelName: " \n "
      )
    }
  }

  @Test func providerCapabilitySeparatesConfigurationFromReadiness() {
    #expect(LocalAIProviderReadiness.ready.canSend)
    #expect(LocalAIProviderReadiness.configured.canSend)
    #expect(LocalAIProviderReadiness.configured != .ready)
    #expect(!LocalAIProviderReadiness.unavailable.canSend)
    #expect(!LocalAIProviderReadiness.checking.canSend)
    #expect(LocalAIProviderReadiness.checking.isConfigurationValid)
    #expect(!LocalAIProviderReadiness.quotaExceeded.canSend)
    #expect(LocalAIProviderReadiness.quotaExceeded.isConfigurationValid)
    #expect(!LocalAIProviderReadiness.unsupportedLocale.canSend)
    #expect(!LocalAIProviderReadiness.invalidConfiguration.canSend)
    #expect(!LocalAIProviderReadiness.invalidConfiguration.isConfigurationValid)
  }
}

@Test func remoteIPv6LoopbackBaseURLIsAccepted() {
  #expect(RemoteLanguageModelConfiguration.endpointURL(from: "http://[::1]:9000/v1") != nil)
}

@Test func generationTemperaturePolicyMatchesNativeContract() {
  #expect(GenerationPolicy.acceptsTemperature(0))
  #expect(GenerationPolicy.acceptsTemperature(1))
  #expect(GenerationPolicy.acceptsTemperature(0.5))
  #expect(!GenerationPolicy.acceptsTemperature(-0.000001))
  #expect(!GenerationPolicy.acceptsTemperature(1.000001))
  #expect(!GenerationPolicy.acceptsTemperature(.infinity))
  #expect(!GenerationPolicy.acceptsTemperature(.nan))
}
