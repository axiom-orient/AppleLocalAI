import FoundationModels

// Prefer DynamicProfile over an app-owned model/tool state machine when a
// continuous session must change instructions, tools, or model configuration.
struct ConciseProfile: LanguageModelSession.DynamicProfile {
  var body: some LanguageModelSession.DynamicProfile {
    Profile {
      Instructions("Answer directly. Omit background that is not needed to complete the task.")
    }
  }
}
