import FoundationModels

// Native app path: use Foundation Models directly. No provider wrapper.
func makeSystemSession() throws -> LanguageModelSession {
  let model = SystemLanguageModel.default
  guard case .available = model.availability else {
    throw SystemModelUnavailable()
  }
  let session = LanguageModelSession(
    model: model,
    instructions: "Answer concisely and use only information required for the task."
  )
  session.prewarm(promptPrefix: nil)
  return session
}

private struct SystemModelUnavailable: Error {}
