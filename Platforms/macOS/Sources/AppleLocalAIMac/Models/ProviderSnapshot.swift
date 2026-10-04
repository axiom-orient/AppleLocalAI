#if os(macOS)

  import AppleLocalAIHost

  struct ProviderSnapshot: Equatable, Identifiable, Sendable {
    let provider: LocalProviderChoice
    let readiness: LocalAIProviderReadiness
    let status: String
    let reason: String
    let model: String
    let context: String
    let capabilities: String
    let imageInput: String

    var id: LocalProviderChoice { provider }
  }

#endif
