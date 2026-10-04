#if os(macOS)
  import AppleLocalAI
  import AppleLocalAICore
  import Foundation
  import FoundationModels

  extension AppleLocalAIModelReadiness {
    public static func evaluate(
      _ model: SystemLanguageModel, locale: Locale = .current
    ) -> Self {
      AppleLocalAISystemReadiness(model: model, locale: locale).status
    }

    public static func isReady(
      _ model: SystemLanguageModel, locale: Locale = .current
    ) -> Bool {
      evaluate(model, locale: locale) == .ready
    }
  }
#endif
