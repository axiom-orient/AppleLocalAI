import AppleLocalAIFoundationModels
import AppleLocalAIHost
import AppleLocalAILiteRT
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAIMac

private func makeMLXFixtureDirectory() throws -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleLocalAI-MLX-Fixture-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data(#"{"model_type":"llama"}"#.utf8).write(
    to: directory.appendingPathComponent("config.json"))
  try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
  try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
  return directory.path
}

@MainActor
private final class MemorySettings: ProviderSettingsStore {
  var value = ProviderSettings.standard
  init() throws {
    value.provider = .mlx
    value.workload = .manual
    value.mlx.modelPath = try makeMLXFixtureDirectory()
  }
  func load() -> ProviderSettings { value }
  func save(_ settings: ProviderSettings) { value = settings }
}

@MainActor
private final class MemoryRemoteCredentialStore: RemoteCredentialStore {
  var value: String?

  init(value: String? = nil) {
    self.value = value
  }

  func load() throws -> String? { value }

  func save(_ secret: String?) throws {
    value = secret
  }
}

@Suite("App request isolation")
@MainActor
struct RequestIsolationTests {
  @Test func corruptedSettingsAreObservableAndReplacedOnlyByASuccessfulSave() throws {
    let suiteName = "AppleLocalAI-Settings-Test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("{".utf8), forKey: UserDefaultsProviderSettingsStore.storageKey)

    let store = UserDefaultsProviderSettingsStore(defaults: defaults)
    #expect(store.load() == .standard)
    #expect(store.persistenceErrorMessage != nil)

    var replacement = ProviderSettings.standard
    replacement.provider = .remote
    store.save(replacement)
    #expect(store.persistenceErrorMessage == nil)
    let saved = try #require(
      defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey))
    #expect(try JSONDecoder().decode(ProviderSettings.self, from: saved) == replacement)
  }

  @Test func malformedNumericDraftDoesNotClearCommittedGenerationSetting() throws {
    let model = AppleIntelligenceModel(settingsStore: try MemorySettings())
    model.foundationTemperatureText = "0.5"
    #expect(model.foundationTemperatureText == "0.5")
    model.foundationTemperatureText = "not-a-number"
    #expect(model.foundationTemperatureText == "0.5")
  }

  @Test func invalidRemoteCredentialIsObservableAndReplacedOnlyByValidSave() throws {
    let settings = try MemorySettings()
    settings.value.provider = .remote
    settings.value.remote.baseURL = "https://example.invalid/v1"
    settings.value.remote.modelName = "remote-model"
    let invalid = "stored\ncredential"
    let credentials = MemoryRemoteCredentialStore(value: invalid)
    let model = AppleIntelligenceModel(
      settingsStore: settings, remoteCredentialStore: credentials)

    #expect(credentials.value == invalid)
    #expect(model.remoteAPIKey.isEmpty)
    #expect(!model.remoteConfigurationIsValid)

    model.remoteAPIKey = "  replacement-key  "
    #expect(credentials.value == "replacement-key")
    #expect(model.remoteAPIKey == "replacement-key")
    #expect(model.remoteConfigurationIsValid)
  }

  @Test func remoteCredentialControlsNeverReachTheCredentialStore() throws {
    let settings = try MemorySettings()
    settings.value.provider = .remote
    settings.value.remote.baseURL = "https://example.invalid/v1"
    settings.value.remote.modelName = "remote-model"
    let credentials = MemoryRemoteCredentialStore()
    let model = AppleIntelligenceModel(
      settingsStore: settings, remoteCredentialStore: credentials)

    model.remoteAPIKey = "injected\r\nX-Injected: true"
    #expect(credentials.value == nil)
    #expect(model.remoteAPIKey.isEmpty)
    #expect(!model.remoteConfigurationIsValid)
  }

  @Test func outOfRangeTemperatureIsRejectedBeforeInference() throws {
    let model = AppleIntelligenceModel(settingsStore: try MemorySettings())
    model.foundationTemperatureText = "1.1"
    model.prompt = "hello"
    model.respond()
    #expect(!model.isBusy)
    #expect(model.errorMessage?.contains("0 이상 1 이하") == true)
  }

  @Test func settingsRevokeRunningOperationSynchronously() async throws {
    let model = AppleIntelligenceModel(settingsStore: try MemorySettings())
    model.prompt = "hello"
    model.respond()
    let operation = try #require(model.lifecycle.operation)
    model.mlxModelPath = try makeMLXFixtureDirectory()
    #expect(model.lifecycle == .cancelling(operation))
    model.finishResponse(answer: "obsolete answer", operation: operation)
    #expect(model.answer.isEmpty)
    model.stopResponding()
    model.stopResponding()
    for _ in 0..<50 where model.isBusy { await Task.yield() }
    #expect(!model.isBusy)
    #expect(model.answer.isEmpty)
  }

  @Test func whitespaceCompletionSettlesAsFailure() throws {
    let model = AppleIntelligenceModel(settingsStore: try MemorySettings())
    model.prompt = "hello"
    model.respond()
    let operation = try #require(model.lifecycle.operation)
    model.finishResponse(answer: " \n ", operation: operation)
    #expect(!model.lifecycle.isBusy)
    #expect(!model.isBusy)
    #expect(model.answer.isEmpty)
    #expect(model.errorMessage != nil)
    model.finishResponse(answer: "late success", operation: operation)
    #expect(model.answer.isEmpty)
  }

  @Test func staleCompletionCannotFinishAReplacementOperation() throws {
    let model = AppleIntelligenceModel(settingsStore: try MemorySettings())
    model.prompt = "first"
    model.respond()
    let first = try #require(model.lifecycle.operation)
    model.finishResponse(answer: "first answer", operation: first)

    model.prompt = "second"
    model.respond()
    let second = try #require(model.lifecycle.operation)
    #expect(first != second)
    model.finishResponse(answer: "obsolete answer", operation: first)
    #expect(model.lifecycle == .running(second))
    #expect(model.answer.isEmpty)

    model.finishResponse(answer: "second answer", operation: second)
    #expect(model.answer == "second answer")
    #expect(!model.isBusy)
  }

  @Test func mlxVisionMetadataReachesTheActualSession() async throws {
    let store = try MemorySettings()
    let directory = URL(fileURLWithPath: store.value.mlx.modelPath)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"model_type":"fixture","vision_config":{}}"#.utf8)
      .write(to: directory.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("processor_config.json"))
    let model = AppleIntelligenceModel(settingsStore: store)
    #expect(model.canAttachImage)
    model.pendingImage = ConversationImage(url: directory.appendingPathComponent("image.png"))
    // Session construction must not reject the capability advertised by the UI.
    // The synthetic weights are never loaded or used as inference evidence.
    _ = try await model.makeOrReuseSession()
  }

  @Test func liteRTVisionRequiresAnAdvertisedModelCapability() {
    let disabled = LiteRTProviderSettings(modelPath: "/tmp/model.litertlm", backend: .cpu)
    #expect(!LocalLanguageModels.liteRTCapabilities(settings: disabled).contains(.vision))

    let enabled = LiteRTProviderSettings(
      modelPath: "/tmp/model.litertlm",
      backend: .gpu,
      visionBackend: .gpu
    )
    #expect(!LocalLanguageModels.liteRTCapabilities(settings: enabled).contains(.vision))
  }

  @Test func liteRTPathNormalizationMatchesTheRuntimeFactoryBoundary() throws {
    #expect(
      NativeModelResourcePolicy.normalizedLiteRTModelPath(
        "  /tmp/model.litertlm\n") == "/tmp/model.litertlm")
    #expect(NativeModelResourcePolicy.normalizedLiteRTModelPath(" \n\t") == "")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleLocalAI-LiteRT-Identity-" + UUID().uuidString)
    let target = root.appendingPathComponent("target.litertlm")
    let link = root.appendingPathComponent("current.litertlm")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("model".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(NativeModelResourcePolicy.normalizedLiteRTModelPath(link.path) == target.path)
  }

  @Test func mlxPathNormalizationMatchesTheRuntimeFactoryBoundary() throws {
    #expect(
      NativeModelResourcePolicy.normalizedMLXModelPath(
        "  /tmp/model-directory\n") == "/tmp/model-directory")
    #expect(NativeModelResourcePolicy.normalizedMLXModelPath(" \n\t") == "")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleLocalAI-MLX-Identity-" + UUID().uuidString)
    let target = root.appendingPathComponent("target", isDirectory: true)
    let link = root.appendingPathComponent("current", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(NativeModelResourcePolicy.normalizedMLXModelPath(link.path) == target.path)
  }

  @Test func targetProviderToolsDoNotUseTheCurrentlyDisplayedProvider() throws {
    let store = try MemorySettings()
    let directory = URL(fileURLWithPath: store.value.mlx.modelPath)
    try Data(#"{"model_type":"fixture","vision_config":{}}"#.utf8)
      .write(to: directory.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: directory.appendingPathComponent("processor_config.json"))
    store.value.provider = .remote

    let model = AppleIntelligenceModel(settingsStore: store)
    model.foundationToolCallingMode = .allowed
    model.foundationEnableOCRTool = true

    #expect(model.currentTools(for: .mlx).count == 1)
  }

  @Test func modelSwitchReleaseBoundaryTracksOnlyChangedLocalResources() {
    let oldLiteRT = ProviderSettings(
      provider: .liteRT,
      mlx: .standard,
      liteRT: LiteRTProviderSettings(
        modelPath: "  /tmp/model-a.litertlm\n", backend: .gpu, visionBackend: .disabled))
    var sameLiteRT = oldLiteRT
    sameLiteRT.liteRT.modelPath = "/tmp/model-a.litertlm"
    #expect(
      !NativeModelResourcePolicy.nativeResourceNeedsRelease(
        oldProvider: .liteRT,
        oldSettings: oldLiteRT,
        newProvider: .liteRT,
        newSettings: sameLiteRT))

    var changedBackend = sameLiteRT
    changedBackend.liteRT.backend = .cpu
    #expect(
      NativeModelResourcePolicy.nativeResourceNeedsRelease(
        oldProvider: .liteRT,
        oldSettings: oldLiteRT,
        newProvider: .liteRT,
        newSettings: changedBackend))

    let oldMLX = ProviderSettings(
      provider: .mlx,
      mlx: MLXProviderSettings(
        modelPath: "  /tmp/model-a\n", guidedGeneration: true, toolCalling: false,
        reasoning: false),
      liteRT: .standard)
    var sameMLX = oldMLX
    sameMLX.mlx.modelPath = "/tmp/model-a"
    #expect(
      !NativeModelResourcePolicy.nativeResourceNeedsRelease(
        oldProvider: .mlx,
        oldSettings: oldMLX,
        newProvider: .mlx,
        newSettings: sameMLX))

    var changedMLX = sameMLX
    changedMLX.mlx.modelPath = "/tmp/model-b"
    #expect(
      NativeModelResourcePolicy.nativeResourceNeedsRelease(
        oldProvider: .mlx,
        oldSettings: oldMLX,
        newProvider: .mlx,
        newSettings: changedMLX))

    #expect(
      NativeModelResourcePolicy.nativeResourceNeedsRelease(
        oldProvider: .liteRT,
        oldSettings: oldLiteRT,
        newProvider: .mlx,
        newSettings: oldMLX))
    #expect(
      !NativeModelResourcePolicy.nativeResourceNeedsRelease(
        oldProvider: .apple,
        oldSettings: .standard,
        newProvider: .liteRT,
        newSettings: oldLiteRT))
  }

  @Test func liteRTVisionDefaultsWhenReadingExistingSettings() throws {
    let data = Data(
      #"{"modelPath":"/tmp/model.litertlm","backend":"cpu"}"#.utf8
    )
    let settings = try JSONDecoder().decode(LiteRTProviderSettings.self, from: data)
    #expect(settings.backend == .cpu)
    #expect(settings.visionBackend == .disabled)
  }

  @Test func invalidNativeUsageCannotOverflowTheDiagnosticSnapshot() {
    var snapshot = FoundationModelsUsageSnapshot()
    snapshot.inputTokenCount = .max
    snapshot.outputTokenCount = 1

    #expect(!snapshot.isValid)
    #expect(snapshot.totalTokenCount == nil)
  }

  @Test func promptTokenEstimateAdditionRejectsInvalidNativeCounts() {
    #expect(AppleIntelligenceModel.addingTokenCount(4, 5) == 9)
    #expect(AppleIntelligenceModel.addingTokenCount(.max, 1) == nil)
    #expect(AppleIntelligenceModel.addingTokenCount(-1, 1) == nil)
  }
}

@Test func privateCloudUnknownAndFailuresNeverBecomeReady() {
  #expect(PrivateCloudRuntimeSnapshot.checking.readiness == .checking)
  var snapshot = PrivateCloudRuntimeSnapshot(isChecking: false, isAvailable: true)
  #expect(snapshot.readiness == .unavailable)
  snapshot.supportsCurrentLocale = false
  #expect(snapshot.readiness == .unsupportedLocale)
  snapshot.supportsCurrentLocale = true
  #expect(snapshot.readiness == .ready)
  snapshot.quotaLimitReached = true
  #expect(snapshot.readiness == .quotaExceeded)
  snapshot.quotaLimitReached = false
  snapshot.errorMessage = "runtime lookup failed"
  #expect(snapshot.readiness == .unavailable)
}
