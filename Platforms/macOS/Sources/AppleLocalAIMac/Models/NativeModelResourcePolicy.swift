#if os(macOS)

  import AppleLocalAIFoundationModels

  enum NativeModelResourcePolicy {
    /// Stores the filesystem identity used by an active native profile rather
    /// than the editable spelling from settings. A symlink can be retargeted
    /// without changing that spelling; retaining the canonical target prevents
    /// an old MLX/LiteRT session or global cache entry from being reused.
    static func runtimeSettingsSnapshot(_ settings: ProviderSettings) -> ProviderSettings {
      var snapshot = settings
      snapshot.coreAIModelPath = LocalModelResourceIdentity.normalizedDirectoryPath(
        settings.coreAIModelPath)
      snapshot.mlx.modelPath = LocalModelResourceIdentity.normalizedDirectoryPath(
        settings.mlx.modelPath)
      snapshot.liteRT.modelPath = LocalModelResourceIdentity.normalizedFilePath(
        settings.liteRT.modelPath)
      return snapshot
    }

    /// Reports whether replacing a live profile must evict a process-wide local
    /// model cache before the next profile is constructed.
    static func nativeResourceNeedsRelease(
      oldProvider: LocalProviderChoice,
      oldSettings: ProviderSettings,
      newProvider: LocalProviderChoice,
      newSettings: ProviderSettings
    ) -> Bool {
      switch oldProvider {
      case .mlx:
        guard newProvider == .mlx else { return true }
        return LocalModelResourceIdentity.normalizedDirectoryPath(oldSettings.mlx.modelPath)
          != LocalModelResourceIdentity.normalizedDirectoryPath(newSettings.mlx.modelPath)
      case .liteRT:
        guard newProvider == .liteRT else { return true }
        return LocalModelResourceIdentity.normalizedFilePath(oldSettings.liteRT.modelPath)
          != LocalModelResourceIdentity.normalizedFilePath(newSettings.liteRT.modelPath)
          || oldSettings.liteRT.backend != newSettings.liteRT.backend
          || oldSettings.liteRT.visionBackend != newSettings.liteRT.visionBackend
      case .coreAI, .apple, .privateCloud, .remote:
        return false
      }
    }
  }

#endif
