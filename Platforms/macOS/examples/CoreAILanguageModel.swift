import CoreAILanguageModels
import Foundation
import FoundationModels

// Production custom-model path: depend directly on apple/coreai-models.
func makeCoreAISession(modelDirectory: URL) async throws -> LanguageModelSession {
  let model = try await CoreAILanguageModel(resourcesAt: modelDirectory)
  try await model.load()
  let session = LanguageModelSession(model: model)
  session.prewarm(promptPrefix: nil)
  return session
}

// Keep the CoreAILanguageModel instance at the composition root when explicit
// unload control is required; call model.unload() when product policy releases it.
