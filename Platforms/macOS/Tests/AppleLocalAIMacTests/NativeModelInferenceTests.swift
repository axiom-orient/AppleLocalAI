#if os(macOS)
  import AppleLocalAIHost
  import AppleLocalAIFoundationModels
  import AppleLocalAILiteRT
  import Foundation
  import Testing

  @testable import AppleLocalAIMac

  /// The same app/session path for any compatible local model. Assets, prompts,
  /// expectations and optional images are provided explicitly by the operator.
  @Test(
    .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["APPLELOCALAI_RUN_NATIVE_INFERENCE"] == "1")
  )
  @MainActor
  func realNativeModelInference() async throws {
    registerNativeTestResources()
    let env = ProcessInfo.processInfo.environment
    let runtime = try #require(env["APPLELOCALAI_MODEL_RUNTIME"])
    let prompt = try #require(env["APPLELOCALAI_MODEL_PROMPT"])
    let expected = try #require(env["APPLELOCALAI_MODEL_EXPECTED"])
    try #require(!expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    var settings = ProviderSettings.standard
    settings.workload = .manual
    switch runtime {
    case "system":
      settings.provider = .apple
    case "mlx":
      let path = try #require(env["APPLELOCALAI_MODEL_PATH"])
      settings.provider = .mlx
      settings.mlx.modelPath = path
      settings.mlx.guidedGeneration = false
      settings.mlx.toolCalling = false
      settings.mlx.reasoning = false
    case "litert":
      let path = try #require(env["APPLELOCALAI_MODEL_PATH"])
      settings.provider = .liteRT
      let backend = try #require(
        LiteRTProviderBackendChoice(rawValue: env["APPLELOCALAI_BACKEND"] ?? "cpu"))
      let vision = try #require(
        LiteRTProviderVisionBackendChoice(
          rawValue: env["APPLELOCALAI_VISION_BACKEND"] ?? "disabled"))
      settings.liteRT = .init(modelPath: path, backend: backend, visionBackend: vision)
    default:
      Issue.record("Unknown native runtime: \(runtime)")
      return
    }
    settings.foundationModels.samplingMode = .greedy
    settings.foundationModels.temperature = 0
    settings.foundationModels.maximumResponseTokens =
      Int(env["APPLELOCALAI_MAX_TOKENS"] ?? "384") ?? 384
    settings.foundationModels.reasoningLevel = .none
    settings.foundationModels.toolCallingMode = .disallowed
    settings.foundationModels.responseMode = .text

    let model = AppleIntelligenceModel(settingsStore: NativeInferenceSettingsStore(settings))
    if let image = env["APPLELOCALAI_MODEL_IMAGE"] {
      try #require(FileManager.default.isReadableFile(atPath: image))
      try #require(model.canAttachImage)
      model.selectImage(URL(fileURLWithPath: image))
    }
    print("NATIVE_RUNTIME=\(runtime)")
    if let path = env["APPLELOCALAI_MODEL_PATH"] {
      print("NATIVE_MODEL_PATH=\(path)")
    } else {
      print("NATIVE_MODEL_PATH=system-default")
    }
    print("NATIVE_VISION=\(model.supportsImageInput)")
    try await checkResponse(model, prompt: prompt, expected: expected, label: "FIRST")
    if let followup = env["APPLELOCALAI_FOLLOWUP_PROMPT"] {
      let followupExpected = try #require(env["APPLELOCALAI_FOLLOWUP_EXPECTED"])
      try #require(!followupExpected.isEmpty)
      try await checkResponse(
        model, prompt: followup, expected: followupExpected, label: "FOLLOWUP")
    }
    model.newConversation()
    if runtime == "mlx" { await LocalLanguageModels.releaseMLXResources() }
    if runtime == "litert" { await LocalLanguageModels.releaseLiteRTResources() }
    print("NATIVE_RESOURCES_RELEASED=true")
  }

  @MainActor
  private func checkResponse(
    _ model: AppleIntelligenceModel, prompt: String, expected: String, label: String
  ) async throws {
    let started = Date()
    model.prompt = prompt
    model.respond()
    for _ in 0..<960 {
      if !model.isBusy { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    if model.isBusy { model.stopResponding() }
    print("NATIVE_\(label)_SECONDS=\(Date().timeIntervalSince(started))")
    print("NATIVE_\(label)_RESPONSE=\(model.answer)")
    print("NATIVE_\(label)_ERROR=\(model.errorMessage ?? "")")
    try #require(!model.isBusy)
    try #require(model.errorMessage == nil)
    if ProcessInfo.processInfo.environment["APPLELOCALAI_RESPONSE_FORMAT"] == "json" {
      guard let actual = try? JSONSerialization.jsonObject(with: Data(model.answer.utf8)) else {
        Issue.record("Response is not valid standalone JSON")
        return
      }
      let reference = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as AnyObject
      #expect((actual as? NSDictionary)?.isEqual(reference) == true)
      return
    }
    // Whole response matching prevents
    // a numeric reference such as 3 from
    // silently accepting 13. Punctuation/spacing normalization is explicit.
    let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    #expect(
      model.answer.trimmingCharacters(in: trim).lowercased()
        == expected.trimmingCharacters(in: trim).lowercased())
  }

  @MainActor
  private final class NativeInferenceSettingsStore: ProviderSettingsStore {
    private var settings: ProviderSettings
    init(_ settings: ProviderSettings) { self.settings = settings }
    func load() -> ProviderSettings { settings }
    func save(_ settings: ProviderSettings) { self.settings = settings }
  }
#endif
