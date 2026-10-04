import FoundationModels

/// A thin Foundation Models value. Transcript and conversation state remain
/// owned by `LanguageModelSession`; the LEAP actor owns only native residency.
@available(iOS 27.0, macOS 27.0, *)
public struct LEAPLanguageModel: LanguageModel {
  public typealias Executor = LEAPExecutor

  public let capabilities = LanguageModelCapabilities([.guidedGeneration])
  public let executorConfiguration: LEAPExecutor.Configuration
  public let modelID: String
  public let providerID = "com.applelocalai.leap"

  init(
    runtime: AppleLocalAILEAPRuntime,
    model: AppleLocalAILEAPTextModel
  ) {
    modelID = model.modelID
    executorConfiguration = LEAPExecutor.Configuration(runtime: runtime, model: model)
  }
}
