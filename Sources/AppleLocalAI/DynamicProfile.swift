import FoundationModels

extension SessionPropertyValues {
  @SessionPropertyEntry
  var appleLocalAIProfile: AppleLocalAIProfile? = nil

  @SessionPropertyEntry
  var appleLocalAIToolCallCount: Int = 0
}

struct AppleLocalAIDynamicInstructions: DynamicInstructions, Sendable {
  let instructions: Instructions
  let tools: [any Tool]

  var body: some DynamicInstructions {
    Instructions(instructions)
    tools
  }
}

/// The single root dynamic profile for a session. Configuration changes update a
/// session property; the Foundation Models session and its transcript stay intact.
struct AppleLocalAIRootProfile: LanguageModelSession.DynamicProfile {
  @SessionProperty(\.appleLocalAIProfile) var profile

  var body: some LanguageModelSession.DynamicProfile {
    if let profile {
      AppleLocalAIConfiguredProfile(configuration: profile)
    } else {
      LanguageModelSession.Profile { Instructions("") }
        .onPrompt { _ in throw AppleLocalAIError.profileUnavailable }
    }
  }
}

struct AppleLocalAIConfiguredProfile: LanguageModelSession.DynamicProfile {
  let configuration: AppleLocalAIProfile
  @SessionProperty(\.appleLocalAIToolCallCount) var toolCallCount

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      AppleLocalAIDynamicInstructions(
        instructions: configuration.nativeInstructions,
        tools: configuration.tools
      )
    }
    .model(configuration.model)
    .temperature(configuration.temperature)
    .samplingMode(configuration.samplingMode)
    .maximumResponseTokens(configuration.maximumResponseTokens)
    .reasoningLevel(configuration.reasoningLevel)
    .toolCallingMode(effectiveToolCallingMode)
    // Foundation Models supplies conversational history here; the active leading
    // instructions are defined independently by this profile for each model turn.
    .historyTransform { history in
      configuration.historyPolicy.project(
        history, omitEmptyPrompt: configuration.omitEmptyPromptFromHistory)
    }
    .transcriptErrorHandlingPolicy(configuration.transcriptErrorHandlingPolicy)
    .onPrompt { _ in toolCallCount = 0 }
    .onToolCall { call in
      toolCallCount += 1
      if let preflight = configuration.toolCallPreflight {
        try await preflight(call)
      }
      if case .handoff = configuration.toolCallPolicy {
        throw AppleLocalAIToolHandoff(call: call)
      }
    }
  }

  private var effectiveToolCallingMode: GenerationOptions.ToolCallingMode? {
    guard configuration.toolCallingMode == .required else {
      return configuration.toolCallingMode
    }
    return toolCallCount == 0 ? .required : .allowed
  }
}
