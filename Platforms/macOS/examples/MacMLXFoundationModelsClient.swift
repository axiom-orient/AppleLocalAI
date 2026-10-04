#if os(macOS)
  import Foundation
  import FoundationModels
  import AppleLocalAIFoundationModels

  // Use the same local-only official bridge as the app. Capabilities must match
  // the selected asset; vision metadata selects the official VLM loader.
  func makeLocalMLXSession(
    directory: URL, capabilities: [LanguageModelCapabilities.Capability] = []
  ) throws -> LanguageModelSession {
    let model = try LocalLanguageModels.mlx(directory: directory, capabilities: capabilities)
    return LanguageModelSession(model: model)
  }

#endif
