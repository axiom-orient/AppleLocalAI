import FoundationModels

/// A stable, value-semantic view of the capabilities advertised by an iOS 27
/// Foundation Models language model.
///
/// Foundation Models intentionally exposes capabilities as individual checks
/// rather than as an enumerable collection. This value keeps that native
/// contract while making capability inspection convenient for host products.
public struct AppleLocalAIModelCapabilities: Sendable, Equatable {
  public let supportsVision: Bool
  public let supportsGuidedGeneration: Bool
  public let supportsReasoning: Bool
  public let supportsToolCalling: Bool

  public init(_ capabilities: LanguageModelCapabilities) {
    supportsVision = capabilities.contains(.vision)
    supportsGuidedGeneration = capabilities.contains(.guidedGeneration)
    supportsReasoning = capabilities.contains(.reasoning)
    supportsToolCalling = capabilities.contains(.toolCalling)
  }
}
