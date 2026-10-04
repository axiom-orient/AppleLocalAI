import AppleLocalAI
import AppleLocalAIFoundationModels
import AppleLocalAIHost
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAIMac

/// A deterministic upstream executor fixture; no server or probabilistic inference.
private struct ProfileProbeModel: LanguageModel {
  let name: String
  var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
  var executorConfiguration: String { name }

  struct Executor: LanguageModelExecutor {
    typealias Model = ProfileProbeModel
    init(configuration: String) {}
    func prewarm(model: Model, transcript: Transcript) {}
    func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: Model,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
      #expect(!request.transcript.isEmpty)
      await channel.send(
        .response(
          action: .appendText(
            model.name + ":" + String(request.transcript.count), tokenCount: 1)))
    }
  }
}

@Test @MainActor func canonicalSessionSwitchesModelWithoutLosingHistory() async throws {
  let session = AppleLocalAISession(
    profile: try AppleLocalAIProfile(
      model: ProfileProbeModel(name: "first"),
      instructions: "First instruction"
    )
  )
  let firstResponse = try await session.respond(try AppleLocalAIRequest(text: "Remember this turn"))
  #expect(firstResponse.content.hasPrefix("first:"))
  let firstHistory = session.history
  #expect(firstHistory.count == 2)

  try session.reconfigure(
    try AppleLocalAIProfile(
      model: ProfileProbeModel(name: "second"),
      instructions: "Changed instruction",
      historyPolicy: .recentEntries(1)
    )
  )
  let second = try await session.respond(try AppleLocalAIRequest(text: "Use the second profile"))
  // Current profile instructions and the current prompt are native request
  // configuration; the executor transcript contains only the retained history.
  #expect(second.content == "second:1")
  #expect(Array(session.history.prefix(2)) == firstHistory)
  #expect(session.history.count == 4)
}

private func makeProfileMLXFixtureDirectory() throws -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleLocalAI-Profile-MLX-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data(#"{"model_type":"llama"}"#.utf8).write(
    to: directory.appendingPathComponent("config.json"))
  try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
  try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
  return directory.path
}

@MainActor
private final class ProfileSettingsStore: ProviderSettingsStore {
  var value: ProviderSettings

  init() throws {
    var settings = ProviderSettings(
      provider: .mlx, mlx: .standard, liteRT: .standard, workload: .manual)
    settings.mlx.modelPath = try makeProfileMLXFixtureDirectory()
    value = settings
  }

  func load() -> ProviderSettings { value }
  func save(_ settings: ProviderSettings) { value = settings }
}

@Test @MainActor func configurationEditsReuseTheAppsNativeSession() async throws {
  let app = AppleIntelligenceModel(settingsStore: try ProfileSettingsStore())
  let session = try await app.makeOrReuseSession()
  let activeModel = try #require(session.activeModel)
  let profile = try AppleLocalAIProfile(model: activeModel)
  try session.reset(
    profile: profile,
    history: [.prompt(Transcript.Prompt(segments: [.text(.init(content: "kept"))]))])
  app.mlxModelPath = try makeProfileMLXFixtureDirectory()
  let updated = try await app.makeOrReuseSession()
  #expect(session === updated)
  #expect(updated.history.count == 1)
  app.workload = .manual
  #expect(try await app.makeOrReuseSession() === session)
  app.newConversation()
  #expect(try await app.makeOrReuseSession() !== session)
}
