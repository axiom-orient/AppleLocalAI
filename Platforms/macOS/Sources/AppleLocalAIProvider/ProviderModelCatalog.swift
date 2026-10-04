#if os(macOS)
  import AppleLocalAICore
  import AppleLocalAIHost
  import AppleLocalAIWire
  import AppleLocalAILiteRT
  import AppleLocalAILocalModels
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels

  /// Immutable registrations plus one currently retained native model description.
  /// Not a provider protocol, executor, model cache, or alternate session authority.
  @MainActor
  final class ProviderModelCatalog {
    let configuration: ProviderConfiguration
    private let environment: [String: String]
    private var active:
      (
        id: String,
        backend: ProviderBackend,
        resourceIdentity: String?,
        model: any LanguageModel
      )?

    init(configuration: ProviderConfiguration, environment: [String: String]) {
      self.configuration = configuration
      self.environment = environment
    }

    func select(for request: InferenceRequest) throws -> ProviderProfile {
      let workload = ProviderConfiguration.taskAliases[request.model] ?? .manual
      if workload == .manual, !configuration.profiles.contains(where: { $0.id == request.model }) {
        throw WireError(status: 404, code: "model_not_found", message: "Unknown model profile")
      }
      let candidates = configuration.profiles.map { profile in
        let capabilities = selectionCapabilities(profile)
        return ModelCandidate(
          id: profile.id, location: profile.backend.location,
          available: isConfiguredAvailable(profile)
            && profilePolicyCanBeAdmitted(
              profile, request: request, capabilities: capabilities),
          capabilities: capabilities)
      }
      let decision = try ModelSelectionPolicy.select(
        workload: workload,
        requirements: request.requirements, candidates: candidates,
        allowPrivateCloud: configuration.allowPrivateCloud,
        manualSelection: workload == .manual ? request.model : nil)
      guard let profile = configuration.profiles.first(where: { $0.id == decision.id }) else {
        throw WireError.unavailable("Selected profile disappeared")
      }
      return profile
    }

    func load(_ profile: ProviderProfile) async throws -> any LanguageModel {
      let resourceIdentity = Self.resourceIdentity(for: profile)
      if let active, active.id == profile.id, active.resourceIdentity == resourceIdentity {
        try await checkSystemAvailability(profile)
        return active.model
      }
      try Task.checkCancellation()
      // There is one in-flight native request in this executable. Release the
      // previous backend only at this idle model-switch boundary; the provider's
      // admission gate guarantees no request is borrowing it concurrently.
      if let previous = active {
        active = nil
        await releaseResources(backend: previous.backend, model: previous.model)
      }
      try Task.checkCancellation()
      let model: any LanguageModel
      switch profile.backend {
      case .system:
        try await checkSystemAvailability(profile)
        model = SystemLanguageModel.default
      case .privateCloud:
        try await checkSystemAvailability(profile)
        model = PrivateCloudComputeLanguageModel()
      case .coreAI:
        guard let resourceIdentity else {
          throw WireError.invalid("Core AI profile requires a resource path")
        }
        model = try await LocalLanguageModels.coreAI(
          directory: URL(fileURLWithPath: resourceIdentity, isDirectory: true))
      case .mlx:
        guard let resourceIdentity else {
          throw WireError.invalid("MLX profile requires a resource path")
        }
        model = try LocalLanguageModels.mlx(
          directory: URL(fileURLWithPath: resourceIdentity, isDirectory: true),
          capabilities: nativeCapabilities(profile.capabilities ?? []))
      case .liteRT:
        guard let resourceIdentity else {
          throw WireError.invalid("LiteRT profile requires a resource path")
        }
        model = try LocalLanguageModels.liteRT(
          path: resourceIdentity, useCPU: profile.backendDevice == "cpu")
      case .chatCompletions:
        var headers = [String: String]()
        if let key = profile.credentialEnvironment {
          let secret: String
          do {
            guard let raw = environment[key],
              let normalized = try RemoteCredentialPolicy.normalized(raw)
            else {
              throw WireError.unavailable("Configured upstream credential is missing or invalid")
            }
            secret = normalized
          } catch {
            throw WireError.unavailable("Configured upstream credential is missing or invalid")
          }
          headers["Authorization"] = "Bearer " + secret
        }
        guard let endpoint = profile.resource, let name = profile.remoteModel else {
          throw WireError.invalid("Configured upstream requires resource and remoteModel")
        }
        let remote = try RemoteLanguageModelConfiguration(endpointString: endpoint, modelName: name)
        model = LocalLanguageModels.chatCompletions(
          name: remote.modelName,
          baseURL: remote.endpoint, headers: headers,
          supportsGuidedGeneration: profile.capabilities?.contains(.guidedGeneration) == true)
      }
      do {
        try Task.checkCancellation()
      } catch {
        await releaseResources(backend: profile.backend, model: model)
        throw error
      }
      active = (profile.id, profile.backend, resourceIdentity, model)
      return model
    }

    /// Drops a model that was successfully constructed but failed the
    /// post-load capability admission. Such a model must not remain retained
    /// as evidence for later selection or keep native resources alive.
    func releaseActive(profile: ProviderProfile) async {
      guard let active, active.id == profile.id else { return }
      self.active = nil
      await releaseResources(backend: active.backend, model: active.model)
    }

    private func releaseResources(backend: ProviderBackend, model: any LanguageModel) async {
      switch backend {
      case .coreAI:
        LocalLanguageModels.releaseCoreAIResources(model)
      case .mlx:
        await LocalLanguageModels.releaseMLXResources()
      case .liteRT:
        await LocalLanguageModels.releaseLiteRTResources()
      case .system, .privateCloud, .chatCompletions:
        break
      }
    }

    func effectiveCapabilities(_ profile: ProviderProfile, model: any LanguageModel) -> Set<
      ModelRequirement
    > {
      let actual = requirements(model.capabilities)
      let configured = configuredCapabilities(profile)
      return configured.map { actual.intersection($0) } ?? actual
    }

    private func isConfiguredAvailable(_ profile: ProviderProfile) -> Bool {
      switch profile.backend {
      case .system:
        return AppleLocalAIModelReadiness.isReady(SystemLanguageModel.default)
      case .privateCloud:
        let model = PrivateCloudComputeLanguageModel()
        return configuration.allowPrivateCloud && model.availability == .available
          && !model.quotaUsage.isLimitReached
      case .coreAI:
        guard let rawPath = profile.resource else { return false }
        let path = LocalModelResourceIdentity.normalizedDirectoryPath(rawPath)
        return FileManager.default.isReadableFile(atPath: path)
      case .mlx:
        guard let rawPath = profile.resource else { return false }
        return LocalModelAsset.isMLXModelDirectory(
          at: URL(
            fileURLWithPath: LocalModelResourceIdentity.normalizedDirectoryPath(rawPath),
            isDirectory: true))
      case .liteRT:
        guard let rawPath = profile.resource else { return false }
        let path = LocalModelResourceIdentity.normalizedFilePath(rawPath)
        guard
          FileManager.default.isReadableFile(atPath: path),
          let metadata = LiteRTModelInspector.capabilities(for: URL(fileURLWithPath: path))
        else { return false }
        return metadata.supportsText
      case .chatCompletions: return true  // Configured, NOT a claim of reachable network/inference.
      }
    }
    private func selectionCapabilities(_ profile: ProviderProfile) -> Set<ModelRequirement> {
      if let active, active.id == profile.id,
        active.resourceIdentity == Self.resourceIdentity(for: profile)
      {
        return effectiveCapabilities(profile, model: active.model)
      }
      if let configured = configuredCapabilities(profile) { return configured }
      switch profile.backend {
      case .system: return requirements(SystemLanguageModel.default.capabilities)
      case .privateCloud: return requirements(PrivateCloudComputeLanguageModel().capabilities)
      case .coreAI:
        // A Core AI bundle's capability metadata becomes authoritative only
        // after construction. Keep an undeclared profile eligible for the
        // load-and-check path; NativeProvider.effectiveCapabilities remains
        // the final admission authority and cannot be widened by this set.
        return Set(ModelRequirement.allCases)
      default:
        // No name-based guessing; explicit declarations or a real load are required.
        return []
      }
    }

    /// Preflight evidence is an admission ceiling. A profile declaration can
    /// narrow it, but it cannot grant a capability that the bundle metadata did
    /// not expose. The loaded Foundation Models conformer is intersected again
    /// by `effectiveCapabilities` after construction.
    private func configuredCapabilities(_ profile: ProviderProfile) -> Set<ModelRequirement>? {
      switch profile.backend {
      case .system:
        let actual = requirements(SystemLanguageModel.default.capabilities)
        return capabilityCeiling(profile.capabilities, actual: actual)
      case .privateCloud:
        let actual = requirements(PrivateCloudComputeLanguageModel().capabilities)
        return capabilityCeiling(profile.capabilities, actual: actual)
      case .liteRT:
        guard let rawPath = profile.resource else { return [] }
        let path = LocalModelResourceIdentity.normalizedFilePath(rawPath)
        let metadata = requirements(LocalLanguageModels.liteRTCapabilities(path: path))
        return capabilityCeiling(profile.capabilities, actual: metadata)
      default:
        return profile.capabilities
      }
    }

    private func profilePolicyCanBeAdmitted(
      _ profile: ProviderProfile, request: InferenceRequest,
      capabilities: Set<ModelRequirement>
    ) -> Bool {
      let reasoning = request.reasoning ?? profile.reasoning
      guard reasoning != nil, reasoning != "none" else { return true }
      // Core AI capability metadata is only authoritative after the native
      // bundle is loaded. Keep that backend eligible here and retain the
      // post-load effective-capability check in NativeProvider.
      guard profile.backend != .coreAI || profile.capabilities != nil else { return true }
      return capabilities.contains(.reasoning)
    }

    private static func resourceIdentity(for profile: ProviderProfile) -> String? {
      guard let resource = profile.resource else { return nil }
      switch profile.backend {
      case .coreAI, .mlx:
        return LocalModelResourceIdentity.normalizedDirectoryPath(resource)
      case .liteRT:
        return LocalModelResourceIdentity.normalizedFilePath(resource)
      case .system, .privateCloud, .chatCompletions:
        return nil
      }
    }

    private func checkSystemAvailability(_ profile: ProviderProfile) async throws {
      switch profile.backend {
      case .system:
        let model = SystemLanguageModel.default
        guard AppleLocalAIModelReadiness.isReady(model)
        else {
          throw WireError.unavailable(
            "Apple Intelligence is not ready (availability/context/locale check failed)")
        }
      case .privateCloud:
        let model = PrivateCloudComputeLanguageModel()
        guard configuration.allowPrivateCloud, model.availability == .available,
          !model.quotaUsage.isLimitReached
        else { throw WireError.unavailable("PCC consent, availability or quota check failed") }
        guard try await model.supportsLocale(.current) else {
          throw WireError.unavailable("PCC does not support the current locale")
        }
      default: break
      }
    }
  }

  func requirements(_ capabilities: LanguageModelCapabilities) -> Set<ModelRequirement> {
    var result = Set<ModelRequirement>()
    for (requirement, native) in [
      (ModelRequirement.vision, LanguageModelCapabilities.Capability.vision),
      (.guidedGeneration, .guidedGeneration), (.reasoning, .reasoning),
      (.toolCalling, .toolCalling),
    ] {
      if capabilities.contains(native) { result.insert(requirement) }
    }
    return result
  }
  func nativeCapabilities(_ values: Set<ModelRequirement>) -> [LanguageModelCapabilities.Capability]
  {
    values.map { value in
      switch value {
      case .vision: .vision
      case .guidedGeneration: .guidedGeneration
      case .reasoning: .reasoning
      case .toolCalling: .toolCalling
      }
    }
  }

  /// A declaration may narrow native evidence but must never grant a capability
  /// that the selected runtime cannot actually provide.
  func capabilityCeiling(
    _ declared: Set<ModelRequirement>?, actual: Set<ModelRequirement>
  ) -> Set<ModelRequirement> {
    declared.map { actual.intersection($0) } ?? actual
  }
#endif
