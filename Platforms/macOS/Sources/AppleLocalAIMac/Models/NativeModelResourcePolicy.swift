#if os(macOS)

  import AppleLocalAIFoundationModels

  enum NativeModelResourcePolicy {
    static func normalizedCoreAIModelPath(_ path: String) -> String {
      LocalModelResourceIdentity.normalizedDirectoryPath(path)
    }

    static func normalizedLiteRTModelPath(_ path: String) -> String {
      LocalModelResourceIdentity.normalizedFilePath(path)
    }

    static func normalizedMLXModelPath(_ path: String) -> String {
      LocalModelResourceIdentity.normalizedDirectoryPath(path)
    }

    /// Stores the filesystem identity used by an active native profile rather
    /// than the editable spelling from settings. A symlink can be retargeted
    /// without changing that spelling; retaining the canonical target prevents
    /// an old MLX/LiteRT session or global cache entry from being reused.
    static func runtimeSettingsSnapshot(_ settings: ProviderSettings) -> ProviderSettings {
      var snapshot = settings
      snapshot.coreAIModelPath = normalizedCoreAIModelPath(settings.coreAIModelPath)
      snapshot.mlx.modelPath = normalizedMLXModelPath(settings.mlx.modelPath)
      snapshot.liteRT.modelPath = normalizedLiteRTModelPath(settings.liteRT.modelPath)
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
        return normalizedMLXModelPath(oldSettings.mlx.modelPath)
          != normalizedMLXModelPath(newSettings.mlx.modelPath)
      case .liteRT:
        guard newProvider == .liteRT else { return true }
        return normalizedLiteRTModelPath(oldSettings.liteRT.modelPath)
          != normalizedLiteRTModelPath(newSettings.liteRT.modelPath)
          || oldSettings.liteRT.backend != newSettings.liteRT.backend
          || oldSettings.liteRT.visionBackend != newSettings.liteRT.visionBackend
      case .coreAI, .apple, .privateCloud, .remote:
        return false
      }
    }
  }

#endif
