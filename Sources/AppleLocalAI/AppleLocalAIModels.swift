import AppleLocalAICore
import Foundation
import FoundationModels

public enum AppleLocalAIModels {
  public static func capabilities(
    for model: any LanguageModel
  ) -> AppleLocalAIModelCapabilities {
    AppleLocalAIModelCapabilities(model.capabilities)
  }

  public static func system(
    useCase: SystemLanguageModel.UseCase = .general,
    guardrails: SystemLanguageModel.Guardrails = .default
  ) -> SystemLanguageModel {
    SystemLanguageModel(useCase: useCase, guardrails: guardrails)
  }

  public static func privateCloud() -> PrivateCloudComputeLanguageModel {
    PrivateCloudComputeLanguageModel()
  }
}

public struct AppleLocalAISystemReadiness: Sendable {
  public let availability: SystemLanguageModel.Availability
  public let isAvailable: Bool
  public let capabilities: AppleLocalAIModelCapabilities
  public let contextSize: Int
  public let supportedLanguages: Set<Locale.Language>
  public let variant: SystemLanguageModel.Variant
  public let supportsCurrentLocale: Bool

  /// A point-in-time preflight, not a guarantee of future model availability.
  public var status: AppleLocalAIModelReadiness {
    .evaluate(
      isAvailable: availability == .available && isAvailable,
      contextSize: contextSize,
      supportsLocale: supportsCurrentLocale
    )
  }

  public var isReady: Bool { status == .ready }

  public init(
    model: SystemLanguageModel = .default,
    locale: Locale = .current
  ) {
    availability = model.availability
    isAvailable = model.isAvailable
    capabilities = AppleLocalAIModelCapabilities(model.capabilities)
    contextSize = model.contextSize
    supportedLanguages = model.supportedLanguages
    variant = model.variant
    supportsCurrentLocale = model.supportsLocale(locale)
  }
}

public struct AppleLocalAIPCCReadiness: Sendable {
  public let availability: PrivateCloudComputeLanguageModel.Availability
  public let isAvailable: Bool
  public let capabilities: AppleLocalAIModelCapabilities
  public let quotaUsage: PrivateCloudComputeLanguageModel.QuotaUsage
  public let contextSize: Int
  public let supportedLanguages: Set<Locale.Language>
  public let supportsCurrentLocale: Bool

  public init(
    model: PrivateCloudComputeLanguageModel,
    locale: Locale = .current
  ) async throws {
    availability = model.availability
    isAvailable = model.isAvailable
    capabilities = AppleLocalAIModelCapabilities(model.capabilities)
    quotaUsage = model.quotaUsage
    contextSize = try await model.contextSize
    supportedLanguages = try await model.supportedLanguages
    supportsCurrentLocale = try await model.supportsLocale(locale)
  }
}
