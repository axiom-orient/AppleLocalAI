#if os(macOS)

  import AppleLocalAICore
  import AppleLocalAI
  import AppleLocalAIHost
  import AppleLocalAILiteRT
  import AppleLocalAILocalModels
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels
  import FoundationModelsUtilities
  import CoreAILanguageModels
  import Observation

  @MainActor
  @Observable
  final class AppleIntelligenceModel {
    private enum Policy {
      static let conversationTitleCharacterLimit = 32
      static let prewarmDelayNanoseconds: UInt64 = 1_000_000_000
      static let configurationResetDelayNanoseconds: UInt64 = 350_000_000
    }

    private(set) var systemModel: SystemLanguageModel
    let privateCloudModel = PrivateCloudComputeLanguageModel()

    @ObservationIgnored private let settingsStore: any ProviderSettingsStore
    @ObservationIgnored private let securityScopedResourceAccess: any SecurityScopedResourceAccess
    @ObservationIgnored private let remoteCredentialStore: any RemoteCredentialStore
    private var settings: ProviderSettings
    private var remoteAPIKeyValue = ""
    @ObservationIgnored private var remoteCredentialRevision: UInt64 = 0
    private(set) var remoteCredentialErrorMessage: String?
    private(set) var settingsPersistenceErrorMessage: String?
    private(set) var privateCloudRuntime = PrivateCloudRuntimeSnapshot.checking

    @ObservationIgnored private var session: AppleLocalAISession?
    @ObservationIgnored private var sessionConfiguration: SessionConfiguration?
    private(set) var coreAIModel: CoreAILanguageModel?
    @ObservationIgnored private var loadedCoreAIModelPath: String?
    private(set) var coreAILoading = false
    private(set) var coreAIStatus = "모델 리소스 폴더를 선택하고 로드하세요."
    @ObservationIgnored private var coreAILoadTask: Task<Void, Never>?
    @ObservationIgnored private var coreAILoadRevision = 0
    private(set) var lastSelection: ModelSelection<LocalProviderChoice>?

    var workload: ModelWorkload {
      get { settings.workload }
      set { updateSettings { $0.workload = newValue } }
    }

    var allowPrivateCloud: Bool {
      get { settings.allowPrivateCloud }
      set {
        updateSettings { $0.allowPrivateCloud = newValue }
        if newValue { refreshPrivateCloudRuntime() } else { cancelPrivateCloudRefresh() }
      }
    }

    var coreAIModelPath: String {
      get { settings.coreAIModelPath }
      set {
        guard newValue != settings.coreAIModelPath else { return }
        cancelCoreAILoad()
        updateSettings { $0.coreAIModelPath = newValue }
        if !coreAIModelMatchesConfiguredPath {
          coreAIStatus = "모델 로드 필요"
        }
      }
    }

    func loadCoreAIModel() {
      guard !isBusy, !coreAILoading else { return }
      let modelPath = LocalModelResourceIdentity.normalizedDirectoryPath(coreAIModelPath)
      guard !modelPath.isEmpty else { return }

      cancelConfigurationReset()
      cancelCoreAILoad()
      guard detachCoreAIProfileIfActive() else { return }
      releaseCoreAIModel()
      coreAILoadRevision &+= 1
      let revision = coreAILoadRevision
      coreAILoading = true
      coreAIStatus = "Core AI 모델 로드 중"
      coreAILoadTask = Task { @MainActor [weak self] in
        do {
          let model = try await LocalLanguageModels.coreAI(
            directory: URL(fileURLWithPath: modelPath, isDirectory: true))
          guard let self, !Task.isCancelled, self.coreAILoadRevision == revision else {
            model.unload()
            return
          }
          self.coreAIModel = model
          self.loadedCoreAIModelPath = modelPath
          self.coreAILoadTask = nil
          self.coreAILoading = false
          self.coreAIStatus = "Core AI 모델 준비됨"
        } catch {
          guard let self, self.coreAILoadRevision == revision else { return }
          self.coreAILoadTask = nil
          self.coreAILoading = false
          self.coreAIStatus = error is CancellationError ? "모델 로드 필요" : error.localizedDescription
        }
      }
    }

    private var coreAIModelMatchesConfiguredPath: Bool {
      guard coreAIModel != nil, let loadedCoreAIModelPath else { return false }
      return loadedCoreAIModelPath
        == LocalModelResourceIdentity.normalizedDirectoryPath(coreAIModelPath)
    }

    private func cancelCoreAILoad() {
      coreAILoadRevision &+= 1
      coreAILoadTask?.cancel()
      coreAILoadTask = nil
      coreAILoading = false
    }

    private func detachCoreAIProfileIfActive() -> Bool {
      guard lastSelection?.id == .coreAI else { return true }
      do {
        try session?.clearProfile()
      } catch {
        coreAIStatus = "기존 Core AI 세션을 분리하지 못했습니다. 현재 작업이 끝난 뒤 다시 시도하세요."
        return false
      }
      sessionConfiguration = nil
      return true
    }

    private func releaseCoreAIModel() {
      coreAIModel?.unload()
      coreAIModel = nil
      loadedCoreAIModelPath = nil
    }

    private func releaseCoreAIModelIfStale() {
      guard coreAIModel != nil, !coreAIModelMatchesConfiguredPath else { return }
      guard detachCoreAIProfileIfActive() else { return }
      releaseCoreAIModel()
      coreAIStatus = "모델 로드 필요"
    }

    private var taskRequirements: Set<ModelRequirement> {
      var requirements: Set<ModelRequirement> = []
      let options = settings.foundationModels
      if pendingImage != nil { requirements.insert(.vision) }
      // A model switch must also support attachments retained by its history view.
      if let session {
        for entry in session.history {
          let segments: [Transcript.Segment]
          switch entry {
          case .prompt(let prompt): segments = prompt.segments
          case .response(let response): segments = response.segments
          case .toolOutput(let output): segments = output.segments
          default: segments = []
          }
          if segments.contains(where: { if case .attachment = $0 { true } else { false } }) {
            requirements.insert(.vision)
          }
        }
      }
      if options.responseMode != .text { requirements.insert(.guidedGeneration) }
      if options.reasoningLevel != .none { requirements.insert(.reasoning) }
      if options.enabledToolCount > 0 || options.toolCallingMode == .required {
        requirements.insert(.toolCalling)
      }
      if options.enableOCRTool || options.enableBarcodeReaderTool || options.enableImageMetadataTool
      {
        requirements.insert(.vision)
      }
      return requirements
    }

    private func requirements(_ capabilities: LanguageModelCapabilities?) -> Set<ModelRequirement> {
      guard let capabilities else { return [] }
      var result: Set<ModelRequirement> = []
      if capabilities.contains(.vision) { result.insert(.vision) }
      if capabilities.contains(.guidedGeneration) { result.insert(.guidedGeneration) }
      if capabilities.contains(.reasoning) { result.insert(.reasoning) }
      if capabilities.contains(.toolCalling) { result.insert(.toolCalling) }
      return result
    }

    private var selection: Result<ModelSelection<LocalProviderChoice>, Error> {
      selectModel(requiring: taskRequirements)
    }

    private func selectModel(requiring required: Set<ModelRequirement>) -> Result<
      ModelSelection<LocalProviderChoice>, Error
    > {
      Result {
        try ModelSelectionPolicy.select(
          workload: settings.workload,
          requirements: required,
          candidates: [
            ModelCandidate(
              id: .apple, location: .system,
              available: AppleLocalAIModelReadiness.isReady(systemModel),
              capabilities: requirements(systemModel.capabilities)),
            ModelCandidate(
              id: .coreAI, location: .customLocal,
              available: coreAIModelMatchesConfiguredPath,
              capabilities: requirements(
                Self.capabilitiesIfCurrent(
                  coreAIModel?.capabilities,
                  isCurrent: coreAIModelMatchesConfiguredPath))),
            ModelCandidate(
              id: .liteRT, location: .customLocal,
              available: liteRTModelPathIsValid,
              capabilities: requirements(
                LocalLanguageModels.liteRTCapabilities(settings: settings.liteRT))),
            ModelCandidate(
              id: .privateCloud, location: .privateCloud,
              available: privateCloudRuntime.readiness == .ready,
              capabilities: requirements(privateCloudModel.capabilities)),
            ModelCandidate(
              id: .mlx, location: .customLocal,
              available: mlxModelPathIsValid, capabilities: requirements(mlxCapabilities)),
            ModelCandidate(
              id: .remote, location: .externalServer,
              available: remoteConfigurationIsValid, capabilities: requirements(remoteCapabilities)),
          ],
          allowPrivateCloud: settings.allowPrivateCloud,
          manualSelection: settings.provider
        )
      }
    }

    var routingReason: String {
      switch selection {
      case .success(let selection):
        return workload.title + " → " + selection.id.title + " · " + selection.reason
      case .failure(let error): return error.localizedDescription
      }
    }

    var runtimeRevisionLabel: String {
      ProcessInfo.processInfo.operatingSystemVersionString + " · " + systemModel.variant.displayName
        + " · model revision: SDK 미공개"
    }

    var lastRoutingLabel: String {
      guard let lastSelection else { return "아직 요청 없음" }
      return lastSelection.id.title + " · " + lastSelection.reason
    }
    private(set) var conversationState: ConversationState = .empty
    private var usageSnapshot = FoundationModelsUsageSnapshot()
    private var estimatedPromptTokenCount: Int?
    private var transcriptEntryCount = 0
    @ObservationIgnored private var historyEntryCountBeforeCurrentTurn: Int?
    private var activeToolNames: [String] = []
    private var lastFeedbackLabel: String?

    @ObservationIgnored private(set) var lifecycle = OperationLifecycle()
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var configurationResetTask: Task<Void, Never>?
    @ObservationIgnored private var nativeResourceReleaseTask: Task<Void, Error>?
    @ObservationIgnored private var nativeResourceReleaseRevision: UInt64 = 0
    @ObservationIgnored private var privateCloudRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var tokenCountTask: Task<Void, Never>?
    @ObservationIgnored private var tokenCountOperation: OperationID?
    @ObservationIgnored private var configurationRevision = 0
    @ObservationIgnored private var privateCloudRevision = 0
    @ObservationIgnored private var pendingAction: PendingResponseAction?

    var provider: LocalProviderChoice {
      if lifecycle.isBusy, let lastSelection { return lastSelection.id }
      return (try? selection.get().id) ?? settings.provider
    }

    var mlxModelPath: String {
      get { settings.mlx.modelPath }
      set { updateSettings { $0.mlx.modelPath = newValue } }
    }

    var mlxGuidedGeneration: Bool {
      get { settings.mlx.guidedGeneration }
      set { updateSettings { $0.mlx.guidedGeneration = newValue } }
    }

    var mlxToolCalling: Bool {
      get { settings.mlx.toolCalling }
      set { updateSettings { $0.mlx.toolCalling = newValue } }
    }

    var mlxReasoning: Bool {
      get { settings.mlx.reasoning }
      set { updateSettings { $0.mlx.reasoning = newValue } }
    }

    var liteRTModelPath: String {
      get { settings.liteRT.modelPath }
      set { updateSettings { $0.liteRT.modelPath = newValue } }
    }

    var liteRTBackend: LiteRTProviderBackendChoice {
      get { settings.liteRT.backend }
      set { updateSettings { $0.liteRT.backend = newValue } }
    }

    var liteRTVisionBackend: LiteRTProviderVisionBackendChoice {
      get { settings.liteRT.visionBackend }
      set { updateSettings { $0.liteRT.visionBackend = newValue } }
    }

    var remoteBaseURL: String {
      get { settings.remote.baseURL }
      set { updateSettings { $0.remote.baseURL = newValue } }
    }

    var remoteModelName: String {
      get { settings.remote.modelName }
      set { updateSettings { $0.remote.modelName = newValue } }
    }

    var remoteVision: Bool {
      get { settings.remote.vision }
      set { updateSettings { $0.remote.vision = newValue } }
    }

    var remoteGuidedGeneration: Bool {
      get { settings.remote.guidedGeneration }
      set { updateSettings { $0.remote.guidedGeneration = newValue } }
    }

    var remoteToolCalling: Bool {
      get { settings.remote.toolCalling }
      set { updateSettings { $0.remote.toolCalling = newValue } }
    }

    var remoteReasoning: Bool {
      get { settings.remote.reasoning }
      set { updateSettings { $0.remote.reasoning = newValue } }
    }

    var remoteAPIKey: String {
      get { remoteAPIKeyValue }
      set {
        guard newValue != remoteAPIKeyValue else { return }
        do {
          let normalized = try RemoteCredentialPolicy.normalized(newValue)
          try remoteCredentialStore.save(normalized)
          remoteAPIKeyValue = normalized ?? ""
          remoteCredentialRevision &+= 1
          remoteCredentialErrorMessage = nil
          if lifecycle.isBusy {
            request(.configurationChanged)
          } else {
            scheduleConfigurationReset()
          }
        } catch {
          remoteCredentialErrorMessage = error.localizedDescription
        }
      }
    }

    var foundationModelUseCase: FoundationModelUseCase {
      get { settings.foundationModels.useCase }
      set { updateSettings { $0.foundationModels.useCase = newValue } }
    }

    var foundationModelGuardrails: FoundationModelGuardrails {
      get { settings.foundationModels.guardrails }
      set { updateSettings { $0.foundationModels.guardrails = newValue } }
    }

    var foundationResponseMode: FoundationModelResponseMode {
      get { settings.foundationModels.responseMode }
      set { updateSettings { $0.foundationModels.responseMode = newValue } }
    }

    var foundationSamplingMode: FoundationModelSamplingMode {
      get { settings.foundationModels.samplingMode }
      set { updateSettings { $0.foundationModels.samplingMode = newValue } }
    }

    var foundationRandomTopK: Int {
      get { settings.foundationModels.randomTopK }
      set { updateSettings { $0.foundationModels.randomTopK = newValue } }
    }

    var foundationProbabilityThreshold: Double {
      get { settings.foundationModels.probabilityThreshold }
      set { updateSettings { $0.foundationModels.probabilityThreshold = newValue } }
    }

    var foundationRandomSeedText: String {
      get { settings.foundationModels.randomSeed.map(String.init) ?? "" }
      set {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
          updateSettings { $0.foundationModels.randomSeed = nil }
        } else if let parsed = UInt64(value) {
          updateSettings { $0.foundationModels.randomSeed = parsed }
        }
      }
    }

    var foundationTemperatureText: String {
      get {
        settings.foundationModels.temperature.map { String($0) } ?? ""
      }
      set {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
          updateSettings { $0.foundationModels.temperature = nil }
        } else if let parsed = Double(value), parsed.isFinite {
          updateSettings { $0.foundationModels.temperature = parsed }
        }
      }
    }

    var foundationMaximumResponseTokensText: String {
      get {
        settings.foundationModels.maximumResponseTokens.map(String.init) ?? ""
      }
      set {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
          updateSettings { $0.foundationModels.maximumResponseTokens = nil }
        } else if let parsed = Int(value) {
          updateSettings { $0.foundationModels.maximumResponseTokens = parsed }
        }
      }
    }

    var foundationReasoningLevel: FoundationModelReasoningLevel {
      get { settings.foundationModels.reasoningLevel }
      set { updateSettings { $0.foundationModels.reasoningLevel = newValue } }
    }

    var foundationCustomReasoningLevel: String {
      get { settings.foundationModels.customReasoningLevel }
      set { updateSettings { $0.foundationModels.customReasoningLevel = newValue } }
    }

    var foundationToolCallingMode: FoundationModelToolCallingMode {
      get { settings.foundationModels.toolCallingMode }
      set { updateSettings { $0.foundationModels.toolCallingMode = newValue } }
    }

    var foundationIncludeSchemaInPrompt: Bool {
      get { settings.foundationModels.includeSchemaInPrompt }
      set { updateSettings { $0.foundationModels.includeSchemaInPrompt = newValue } }
    }

    var foundationHistoryEntryLimit: Int {
      get { settings.foundationModels.historyEntryLimit }
      set { updateSettings { $0.foundationModels.historyEntryLimit = newValue } }
    }

    var foundationEnableOCRTool: Bool {
      get { settings.foundationModels.enableOCRTool }
      set { updateSettings { $0.foundationModels.enableOCRTool = newValue } }
    }

    var foundationEnableBarcodeReaderTool: Bool {
      get { settings.foundationModels.enableBarcodeReaderTool }
      set { updateSettings { $0.foundationModels.enableBarcodeReaderTool = newValue } }
    }

    var foundationEnableImageMetadataTool: Bool {
      get { settings.foundationModels.enableImageMetadataTool }
      set { updateSettings { $0.foundationModels.enableImageMetadataTool = newValue } }
    }

    var foundationEnableSpotlightSearchTool: Bool {
      get { settings.foundationModels.enableSpotlightSearchTool }
      set { updateSettings { $0.foundationModels.enableSpotlightSearchTool = newValue } }
    }

    var prompt = ""
    var pendingImage: ConversationImage?

    init(
      settingsStore: any ProviderSettingsStore = UserDefaultsProviderSettingsStore(),
      securityScopedResourceAccess: any SecurityScopedResourceAccess =
        SystemSecurityScopedResourceAccess(),
      remoteCredentialStore: any RemoteCredentialStore = KeychainRemoteCredentialStore()
    ) {
      self.settingsStore = settingsStore
      self.securityScopedResourceAccess = securityScopedResourceAccess
      self.remoteCredentialStore = remoteCredentialStore
      do {
        remoteAPIKeyValue =
          try RemoteCredentialPolicy.normalized(remoteCredentialStore.load()) ?? ""
      } catch {
        remoteCredentialErrorMessage = error.localizedDescription
      }
      let loadedSettings = settingsStore.load()
      settingsPersistenceErrorMessage = settingsStore.persistenceErrorMessage
      settings = loadedSettings
      systemModel = SystemLanguageModel(
        useCase: loadedSettings.foundationModels.useCase.nativeValue,
        guardrails: loadedSettings.foundationModels.guardrails.nativeValue
      )

      if loadedSettings.allowPrivateCloud {
        refreshPrivateCloudRuntime()
      }
    }

    isolated deinit {
      responseTask?.cancel()
      coreAILoadTask?.cancel()
      coreAIModel?.unload()
      prewarmTask?.cancel()
      configurationResetTask?.cancel()
      nativeResourceReleaseTask?.cancel()
      privateCloudRefreshTask?.cancel()
      tokenCountTask?.cancel()
    }

    var answer: String {
      conversationState.answer
    }

    var submittedTurn: ConversationTurn? {
      conversationState.submittedTurn
    }

    var historyBeforeCurrentTurn: [Transcript.Entry] {
      guard let session else { return [] }
      let history = session.history
      guard let historyEntryCountBeforeCurrentTurn else { return history }
      return ConversationHistoryProjection.priorEntries(
        in: history,
        beforeEntryCount: historyEntryCountBeforeCurrentTurn
      )
    }

    var errorMessage: String? {
      conversationState.errorMessage
    }

    var isResponding: Bool {
      conversationState.isResponding
    }

    var isCancelling: Bool {
      conversationState.isCancelling
    }

    var isBusy: Bool {
      lifecycle.isBusy
    }

    var pendingImageName: String? {
      pendingImage?.fileName
    }

    var responseText: String {
      conversationState.responseText
    }

    var wasCancelled: Bool {
      conversationState.wasCancelled
    }

    var conversationTitle: String {
      guard
        let submittedPrompt = submittedTurn?.prompt
          ?? ConversationHistoryProjection.latestUserPrompt(in: historyBeforeCurrentTurn)
      else { return "새 대화" }
      let singleLinePrompt = submittedPrompt.replacingOccurrences(of: "\n", with: " ")
      let title = String(singleLinePrompt.prefix(Policy.conversationTitleCharacterLimit))
      return title.count == singleLinePrompt.count ? title : title + "…"
    }

    var hasConversation: Bool {
      submittedTurn != nil
        || ConversationHistoryProjection.latestUserPrompt(in: historyBeforeCurrentTurn) != nil
    }

    var selectedProviderSnapshot: ProviderSnapshot {
      providerSnapshot(for: provider)
    }

    var providerSnapshots: [ProviderSnapshot] {
      LocalProviderChoice.allCases.map(providerSnapshot(for:))
    }

    func providerSnapshot(for provider: LocalProviderChoice) -> ProviderSnapshot {
      ProviderSnapshot(
        provider: provider,
        readiness: providerReadiness(for: provider),
        status: providerStatus(for: provider),
        reason: provider == self.provider ? routingReason : providerDescription(for: provider),
        model: providerModelIdentity(for: provider),
        context: providerContext(for: provider),
        capabilities: providerCapabilitiesLabel(for: provider),
        imageInput: providerImageInputLabel(for: provider)
      )
    }

    var providerBadgeTitle: String {
      if case .failure = selection, !isBusy { return "선택 불가" }
      return provider.title
    }

    var modelIdentityTitle: String {
      providerModelIdentity(for: provider)
    }

    var supportsImageInput: Bool {
      activeFoundationLanguageModelCapabilities?.contains(.vision) == true
    }

    var canAttachImage: Bool {
      guard !isBusy else { return false }
      return (try? selectModel(requiring: taskRequirements.union([.vision])).get()) != nil
    }

    var imageInputLabel: String {
      switch provider {
      case .coreAI:
        return supportsImageInput ? "Core AI 이미지 입력 지원" : "Core AI 모델의 Vision capability 없음"
      case .apple:
        guard readiness == .ready else {
          return "Apple Intelligence 준비 후 이미지 분석 가능"
        }
        return supportsImageInput
          ? "이미지 분석 지원"
          : "현재 시스템 모델은 이미지 입력을 지원하지 않음"
      case .privateCloud:
        guard readiness == .ready else {
          return "Private Cloud Compute 준비 후 이미지 분석 가능"
        }
        return supportsImageInput
          ? "Private Cloud 이미지 분석 지원"
          : "Private Cloud 모델은 이미지 입력을 지원하지 않음"
      case .mlx:
        return supportsImageInput
          ? "MLXVLM 이미지 입력 지원"
          : "선택한 MLX 모델은 이미지 입력을 지원하지 않음"
      case .liteRT:
        guard readiness.canSend else { return "LiteRT 모델 준비 후 이미지 분석 가능" }
        return supportsImageInput
          ? "LiteRT Vision 입력 지원"
          : settings.liteRT.visionBackend == .disabled
            ? "LiteRT Vision backend가 꺼져 있음"
            : "선택한 LiteRT 모델에 호환되는 이미지 encoder가 없음"
      case .remote:
        guard readiness.canSend else { return "원격 모델 설정 후 이미지 입력 가능" }
        return supportsImageInput ? "원격 모델 Vision 입력 허용" : "원격 모델 Vision capability를 선언하지 않음"
      }
    }

    var readiness: LocalAIProviderReadiness {
      if case .failure = selection { return .unavailable }
      return providerReadiness(for: provider)
    }

    var availabilityLabel: String {
      if case .failure = selection { return "조건을 만족하는 모델 없음" }
      return providerStatus(for: provider)
    }

    var appleAvailabilityLabel: String {
      switch systemModel.availability {
      case .available:
        return "사용 가능"
      case .unavailable(.deviceNotEligible):
        return "이 기기에서 지원되지 않음"
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Apple Intelligence가 꺼져 있음"
      case .unavailable(.modelNotReady):
        return "모델 준비 중"
      case .unavailable:
        return "사용할 수 없음"
      }
    }

    var contextLabel: String {
      providerContext(for: provider)
    }

    var providerDescription: String {
      providerDescription(for: provider)
    }

    private func providerReadiness(for provider: LocalProviderChoice) -> LocalAIProviderReadiness {
      switch provider {
      case .coreAI:
        return coreAIModelMatchesConfiguredPath
          ? .ready : (coreAILoading ? .checking : .unavailable)
      case .apple:
        switch AppleLocalAIModelReadiness.evaluate(systemModel) {
        case .ready:
          return .ready
        case .unsupportedLocale:
          return .unsupportedLocale
        case .unavailable, .contextUnavailable:
          return .unavailable
        }
      case .privateCloud:
        guard settings.allowPrivateCloud else { return .unavailable }
        return privateCloudRuntime.readiness
      case .mlx:
        return mlxModelPathIsValid ? .configured : .invalidConfiguration
      case .liteRT:
        return liteRTModelPathIsValid ? .configured : .invalidConfiguration
      case .remote:
        return remoteConfigurationIsValid ? .configured : .invalidConfiguration
      }
    }

    private func providerStatus(for provider: LocalProviderChoice) -> String {
      switch provider {
      case .coreAI:
        return coreAIStatus
      case .apple:
        switch AppleLocalAIModelReadiness.evaluate(systemModel) {
        case .unsupportedLocale:
          return "현재 언어 미지원"
        case .contextUnavailable:
          return "모델 준비 상태 확인 필요"
        case .unavailable:
          return appleAvailabilityLabel
        case .ready:
          return "사용 가능"
        }
      case .privateCloud:
        guard settings.allowPrivateCloud else { return "사용 허용 필요" }
        if privateCloudRuntime.isChecking { return "상태 확인 중" }
        if privateCloudRuntime.quotaLimitReached { return "사용량 한도 도달" }
        if privateCloudRuntime.readiness == .unsupportedLocale { return "현재 언어 미지원" }
        return privateCloudRuntime.availabilityLabel
      case .mlx:
        return mlxModelPathIsValid ? "로컬 모델 설정됨 · 실행 미확인" : "모델 폴더 필요"
      case .liteRT:
        return liteRTModelPathIsValid ? "파일 설정됨 · 실행 미확인" : "모델 파일 필요"
      case .remote:
        return remoteConfigurationIsValid
          ? "endpoint 설정됨 · 연결은 요청 시 확인" : "URL과 모델 이름 필요"
      }
    }

    private func providerModelIdentity(for provider: LocalProviderChoice) -> String {
      switch provider {
      case .coreAI:
        let path = coreAIModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "Core AI 모델 미선택" : URL(fileURLWithPath: path).lastPathComponent
      case .apple:
        return systemModel.variant.displayName
      case .privateCloud:
        return "Private Cloud Compute"
      case .mlx:
        let path = mlxModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "MLX 모델 미선택" : URL(fileURLWithPath: path).lastPathComponent
      case .liteRT:
        return settings.liteRT.modelIdentifier
      case .remote:
        let name = settings.remote.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "원격 모델 미설정" : name
      }
    }

    private func providerContext(for provider: LocalProviderChoice) -> String {
      switch provider {
      case .coreAI:
        return "Core AI · 로컬 리소스 · specialization/cache는 Core AI 관리"
      case .apple:
        return "컨텍스트 " + systemModel.contextSize.formatted()
          + " · " + String(systemModel.supportedLanguages.count) + "개 언어"
      case .privateCloud:
        let context = privateCloudRuntime.contextSize.map { $0.formatted() } ?? "확인 중"
        let languageCount = privateCloudRuntime.languageCount.map(String.init) ?? "확인 중"
        return "PCC 컨텍스트 " + context + " · " + languageCount + "개 언어"
      case .mlx:
        let path = mlxModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty
          ? "네이티브 MLX 모델 미선택" : "모델 " + URL(fileURLWithPath: path).lastPathComponent
      case .liteRT:
        return "모델 " + settings.liteRT.modelIdentifier + " · " + liteRTBackend.title
      case .remote:
        return "Foundation Models LanguageModel · "
          + (validatedRemoteConfiguration?.endpoint.host ?? "원격 endpoint")
      }
    }

    private func providerDescription(for provider: LocalProviderChoice) -> String {
      switch provider {
      case .coreAI:
        return "Core AI · 제품 소유 로컬 모델"
      case .apple:
        return "Apple Intelligence · 시스템 모델"
      case .privateCloud:
        return "Private Cloud Compute · 명시적으로 선택한 원격 모델"
      case .mlx:
        return "MLX · Foundation Models 네이티브"
      case .liteRT:
        return "LiteRT · Foundation Models 어댑터"
      case .remote:
        return "원격 LLM · Apple ChatCompletionsLanguageModel"
      }
    }

    private func providerCapabilities(for provider: LocalProviderChoice)
      -> LanguageModelCapabilities?
    {
      switch provider {
      case .coreAI:
        return Self.capabilitiesIfCurrent(
          coreAIModel?.capabilities,
          isCurrent: coreAIModelMatchesConfiguredPath)
      case .apple:
        return systemModel.capabilities
      case .privateCloud:
        return privateCloudModel.capabilities
      case .mlx:
        return mlxCapabilities
      case .liteRT:
        return LocalLanguageModels.liteRTCapabilities(settings: settings.liteRT)
      case .remote:
        return remoteCapabilities
      }
    }

    static func capabilitiesIfCurrent(
      _ capabilities: LanguageModelCapabilities?, isCurrent: Bool
    ) -> LanguageModelCapabilities? {
      guard isCurrent else { return nil }
      return capabilities
    }

    private func providerCapabilitiesLabel(for provider: LocalProviderChoice) -> String {
      guard let capabilities = providerCapabilities(for: provider) else {
        return provider == .coreAI ? "모델 준비 필요" : "확인 불가"
      }
      let supported = FoundationModelCapability.allCases
        .filter { capabilities.contains($0.nativeValue) }
        .map(\.title)
      return supported.isEmpty ? "텍스트" : supported.joined(separator: " · ")
    }

    private func providerImageInputLabel(for provider: LocalProviderChoice) -> String {
      if provider == .liteRT, settings.liteRT.visionBackend == .disabled {
        return "Vision backend 꺼짐"
      }
      guard providerReadiness(for: provider).canSend else {
        return provider.title + " 준비 필요"
      }
      return providerCapabilities(for: provider)?.contains(.vision) == true
        ? "이미지 입력 지원" : "이미지 입력 없음"
    }

    var canSend: Bool {
      !effectivePrompt.isEmpty && !isBusy && requestConfigurationMessage == nil
    }

    var foundationCapabilitiesLabel: String {
      guard let capabilities = activeFoundationLanguageModelCapabilities else {
        return "외부 provider 전용"
      }
      let supported = FoundationModelCapability.allCases
        .filter { capabilities.contains($0.nativeValue) }
        .map(\.title)
      return supported.isEmpty ? "없음" : supported.joined(separator: " · ")
    }

    var foundationResponseModeLabel: String {
      let mode = settings.foundationModels.responseMode
      return mode.title + " · " + mode.subtitle
    }

    var foundationToolNamesLabel: String {
      let names = activeToolNames.isEmpty ? configuredToolNames : activeToolNames
      return names.isEmpty ? "없음" : names.joined(separator: " · ")
    }

    var foundationUsageLabel: String {
      if provider == .liteRT { return "확인 불가 · LiteRT 어댑터의 토큰 사용량은 미검증" }
      guard usageSnapshot.isValid, let totalTokenCount = usageSnapshot.totalTokenCount else {
        return "확인 불가 · native usage accounting invalid"
      }
      return totalTokenCount == 0 ? "아직 없음" : usageSnapshot.description
    }

    var foundationEstimatedTokenLabel: String {
      estimatedPromptTokenCount.map(String.init) ?? "확인 불가"
    }

    var foundationTranscriptLabel: String {
      String(transcriptEntryCount) + "개 항목 · 기본 "
        + String(settings.foundationModels.historyEntryLimit) + "개 · 도구 턴 보존"
    }

    var feedbackLabel: String? {
      lastFeedbackLabel
    }

    var privateCloudQuotaLabel: String {
      if privateCloudRuntime.isChecking { return "상태 확인 중" }
      guard privateCloudRuntime.isAvailable, privateCloudRuntime.errorMessage == nil else {
        return "사용량 확인 불가"
      }
      if privateCloudRuntime.quotaLimitReached {
        guard let resetDate = privateCloudRuntime.quotaResetDate else {
          return "사용량 한도 도달"
        }
        return "한도 도달 · "
          + resetDate.formatted(date: .abbreviated, time: .shortened) + " 초기화"
      }
      return "사용량 한도 내"
    }

    var privateCloudRuntimeErrorMessage: String? {
      privateCloudRuntime.errorMessage
    }

    var hasPrivateCloudQuotaSuggestion: Bool {
      privateCloudModel.quotaUsage.limitIncreaseSuggestion != nil
    }

    var mlxModelPathIsValid: Bool {
      let path = LocalModelResourceIdentity.normalizedDirectoryPath(mlxModelPath)
      guard !path.isEmpty else { return false }
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      return LocalModelAsset.isMLXModelDirectory(at: directory)
    }

    private var mlxCapabilities: LanguageModelCapabilities {
      LanguageModelCapabilities(mlxCapabilityList)
    }

    var liteRTModelPathIsValid: Bool {
      let path = LocalModelResourceIdentity.normalizedFilePath(liteRTModelPath)
      guard !path.isEmpty,
        URL(fileURLWithPath: path).pathExtension.lowercased() == "litertlm"
      else {
        return false
      }
      let url = URL(fileURLWithPath: path)
      return LocalModelAsset.isReadableFile(at: url, extension: "litertlm")
        && LocalModelFileFormat.inspect(url) == .liteRT
        && LiteRTModelInspector.capabilities(for: url)?.supportsText == true
    }

    private var validatedRemoteConfiguration: RemoteLanguageModelConfiguration? {
      try? RemoteLanguageModelConfiguration(
        endpointString: settings.remote.baseURL, modelName: settings.remote.modelName)
    }

    var remoteConfigurationIsValid: Bool {
      validatedRemoteConfiguration != nil && remoteCredentialErrorMessage == nil
    }

    private var remoteCapabilities: LanguageModelCapabilities {
      var values: [LanguageModelCapabilities.Capability] = []
      if settings.remote.vision { values.append(.vision) }
      if settings.remote.guidedGeneration { values.append(.guidedGeneration) }
      if settings.remote.toolCalling { values.append(.toolCalling) }
      if settings.remote.reasoning { values.append(.reasoning) }
      return LanguageModelCapabilities(values)
    }

    private func makeRemoteLanguageModel() throws -> any LanguageModel {
      guard let configuration = validatedRemoteConfiguration else {
        throw ModelSelectionError.noEligibleModel
      }
      let key = try RemoteCredentialPolicy.normalized(remoteAPIKeyValue) ?? ""
      let headers = key.isEmpty ? [:] : ["Authorization": "Bearer " + key]
      return LocalLanguageModels.chatCompletions(
        name: configuration.modelName, baseURL: configuration.endpoint, headers: headers,
        supportsGuidedGeneration: settings.remote.guidedGeneration)
    }

    func refreshPrivateCloudRuntime() {
      privateCloudRefreshTask?.cancel()
      privateCloudRevision &+= 1
      let revision = privateCloudRevision
      privateCloudRuntime = .checking
      let nativeModel = privateCloudModel

      privateCloudRefreshTask = Task { @MainActor [weak self, nativeModel, revision] in
        guard let self, !Task.isCancelled, self.privateCloudRevision == revision,
          self.settings.allowPrivateCloud
        else { return }

        switch nativeModel.availability {
        case .unavailable(.deviceNotEligible):
          self.privateCloudRuntime = Self.privateCloudSnapshot(
            availabilityLabel: "이 기기에서 지원되지 않음",
            isAvailable: false,
            quota: nil,
            supportsCurrentLocale: nil,
            contextSize: nil,
            languageCount: nil,
            errorMessage: nil
          )
        case .unavailable(.systemNotReady):
          self.privateCloudRuntime = Self.privateCloudSnapshot(
            availabilityLabel: "시스템 준비 중",
            isAvailable: false,
            quota: nil,
            supportsCurrentLocale: nil,
            contextSize: nil,
            languageCount: nil,
            errorMessage: nil
          )
        case .available:
          let quota = nativeModel.quotaUsage
          if quota.isLimitReached {
            self.privateCloudRuntime = Self.privateCloudSnapshot(
              availabilityLabel: "사용량 한도 도달",
              isAvailable: true,
              quota: quota,
              supportsCurrentLocale: nil,
              contextSize: nil,
              languageCount: nil,
              errorMessage: nil
            )
            return
          }
          do {
            let contextSize = try await nativeModel.contextSize
            let languages = try await nativeModel.supportedLanguages
            let supportsLocale = try await nativeModel.supportsLocale(.current)
            guard self.privateCloudRevision == revision, self.settings.allowPrivateCloud else {
              return
            }
            self.privateCloudRuntime = Self.privateCloudSnapshot(
              availabilityLabel: "사용 가능",
              isAvailable: true,
              quota: quota,
              supportsCurrentLocale: supportsLocale,
              contextSize: contextSize,
              languageCount: languages.count,
              errorMessage: nil
            )
          } catch {
            guard self.privateCloudRevision == revision, self.settings.allowPrivateCloud else {
              return
            }
            self.privateCloudRuntime = Self.privateCloudSnapshot(
              availabilityLabel: "런타임 확인 실패",
              isAvailable: true,
              quota: quota,
              supportsCurrentLocale: nil,
              contextSize: nil,
              languageCount: nil,
              errorMessage: error.localizedDescription
            )
          }
        case .unavailable:
          self.privateCloudRuntime = Self.privateCloudSnapshot(
            availabilityLabel: "사용할 수 없음",
            isAvailable: false,
            quota: nil,
            supportsCurrentLocale: nil,
            contextSize: nil,
            languageCount: nil,
            errorMessage: nil
          )
        }
      }
    }

    func showPrivateCloudQuotaSuggestion() {
      privateCloudModel.quotaUsage.limitIncreaseSuggestion?.show()
    }

    func selectImage(_ url: URL) {
      guard canAttachImage, url.isFileURL else { return }
      pendingImage = ConversationImage(url: url)
      schedulePrewarm()
    }

    func removePendingImage() {
      guard !isBusy else { return }
      pendingImage = nil
      cancelPrewarm()
    }

    func selectProvider(_ provider: LocalProviderChoice) {
      updateSettings {
        $0.provider = provider
        $0.workload = .manual
      }
      if provider == .privateCloud, allowPrivateCloud { refreshPrivateCloudRuntime() }
    }

    func respond() {
      guard !lifecycle.isBusy else { return }
      historyEntryCountBeforeCurrentTurn = nil
      cancelPrewarm()
      cancelConfigurationReset()

      let selectedImage = pendingImage
      let trimmedPrompt = effectivePrompt
      guard !trimmedPrompt.isEmpty else {
        apply(
          .failBeforeStart(message: "질문을 입력하세요.")
        )
        return
      }

      if let configurationMessage = requestConfigurationMessage {
        apply(
          .failWithInput(
            prompt: trimmedPrompt,
            image: selectedImage,
            message: configurationMessage
          )
        )
        return
      }

      do {
        let requestSettings = settings.foundationModels
        let responseMode = requestSettings.responseMode
        let schema =
          try responseMode == .dynamicSchema
          ? FoundationModelsResponseSchema.dynamic()
          : nil
        let request = try makeRequest(text: trimmedPrompt, image: selectedImage)
        // Keep deterministic selection failures before starting the operation.
        // Native model construction may await a cache-release barrier, so it is
        // performed inside the lifecycle-owned task below.
        _ = try selection.get()
        let operation = OperationID()
        do {
          try lifecycle.start(operation)
        } catch {
          return
        }

        estimatedPromptTokenCount = nil
        apply(.begin(prompt: trimmedPrompt, image: selectedImage))

        let options = GenerationOptions()
        let contextOptions = ContextOptions(
          includeSchemaInPrompt: requestSettings.includeSchemaInPrompt)
        let access = securityScopedResourceAccess

        responseTask = Task {
          @MainActor [
            weak self, request, selectedImage,
            operation, access, responseMode, schema, options, contextOptions
          ] in
          guard let self, self.lifecycle == .running(operation) else { return }

          do {
            try Task.checkCancellation()
            let session = try await self.makeOrReuseSession()
            guard !Task.isCancelled, self.lifecycle == .running(operation) else { return }
            self.historyEntryCountBeforeCurrentTurn = session.history.count

            // Keep the pending image visible to taskRequirements until the
            // selected profile has admitted the current request's capability.
            self.pendingImage = nil
            self.prompt = ""

            let provider = self.provider
            let metadata: [String: any ConvertibleToGeneratedContent] = [
              "provider": provider.rawValue,
              "response_mode": responseMode.rawValue,
              "routing_profile": self.workload.rawValue,
              "selection_reason": self.lastSelection?.reason ?? "",
              "capabilities": self.lastSelection?.capabilities.map(\.rawValue).sorted().joined(
                separator: ",") ?? "",
              "runtime": self.runtimeRevisionLabel,
              "model_identity": self.modelIdentityTitle,
            ]
            self.estimatedPromptTokenCountTask(
              session: session,
              request: request,
              schema: schema,
              tools: self.currentTools(for: provider),
              provider: provider,
              operation: operation
            )

            let finalAnswer = try await SecurityScopedResource.withAccess(
              to: selectedImage?.url, using: access
            ) {
              try await NativeResponseRunner.run(
                session: session,
                request: request,
                mode: responseMode,
                schema: schema,
                options: options,
                contextOptions: contextOptions,
                metadata: metadata
              ) { [weak self, session] snapshot in
                guard let self else { return }
                self.updateUsage(
                  snapshot.usage,
                  transcriptEntries: snapshot.transcriptEntryCount,
                  session: session,
                  operation: operation
                )
                self.updateResponse(answer: snapshot.answer, operation: operation)
              }
            }
            guard !Task.isCancelled else { return }
            self.finishResponse(answer: finalAnswer, operation: operation)
          } catch {
            guard !Task.isCancelled else { return }
            self.failResponse(message: error.localizedDescription, operation: operation)
          }
        }
      } catch {
        apply(
          .failWithInput(
            prompt: trimmedPrompt,
            image: selectedImage,
            message: error.localizedDescription
          )
        )
      }
    }

    func newConversation() {
      request(.newConversation)
    }

    func stopResponding() {
      guard isResponding else { return }
      pendingAction = nil
      beginCancellation()
    }

    func retryLastResponse() {
      guard let turn = submittedTurn else { return }
      request(.retry(prompt: turn.prompt, image: turn.image))
    }

    func logFeedback(
      _ sentiment: LanguageModelFeedback.Sentiment,
      issue: FoundationModelsFeedbackIssueCategory? = nil
    ) {
      guard let session else {
        lastFeedbackLabel = "먼저 native 응답을 생성하세요."
        return
      }

      let data: Data
      do {
        data = try session.feedbackAttachment(
          sentiment: sentiment,
          issues: issue.map {
            [LanguageModelFeedback.Issue(category: $0.nativeValue)]
          } ?? [],
          desiredResponseText: answer.isEmpty ? responseText : answer
        )
      } catch {
        lastFeedbackLabel = error.localizedDescription
        return
      }
      if sentiment == .positive {
        lastFeedbackLabel = "좋은 응답으로 기록됨 · " + String(data.count) + " bytes"
      } else if let issue {
        lastFeedbackLabel = issue.title + " · " + String(data.count) + " bytes"
      } else {
        lastFeedbackLabel = "개선이 필요한 응답으로 기록됨 · " + String(data.count) + " bytes"
      }
    }

    func schedulePrewarm() {
      cancelPrewarm()
      guard provider == .apple || provider == .privateCloud, readiness == .ready, !isBusy else {
        return
      }

      let trimmedPrompt = effectivePrompt
      guard !trimmedPrompt.isEmpty else { return }
      let image = pendingImage
      let request = try? makeRequest(text: trimmedPrompt, image: image)
      let access = securityScopedResourceAccess

      prewarmTask = Task { @MainActor [weak self, request, image, access] in
        do {
          try await Task.sleep(nanoseconds: Policy.prewarmDelayNanoseconds)
          guard !Task.isCancelled,
            let self,
            self.provider == .apple || self.provider == .privateCloud,
            self.readiness == .ready,
            !self.isBusy,
            self.requestConfigurationMessage == nil
          else {
            return
          }

          let session = try await self.makeOrReuseSession()
          try await SecurityScopedResource.withAccess(to: image?.url, using: access) {
            guard !Task.isCancelled else { throw CancellationError() }
            if let request {
              try session.prewarm(promptPrefix: request.prompt)
            }
          }
        } catch {
          // Prewarming is an optimization. It must not affect request state.
        }
      }
    }

    private var effectivePrompt: String {
      let typedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      return typedPrompt.isEmpty && pendingImage != nil ? "이 이미지를 분석해줘." : typedPrompt
    }

    private var activeFoundationLanguageModelCapabilities: LanguageModelCapabilities? {
      providerCapabilities(for: provider)
    }

    private var configuredToolNames: [String] {
      currentTools(for: provider).map(\.name)
    }

    func currentTools(for selectedProvider: LocalProviderChoice) -> [any Tool] {
      guard let capabilities = providerCapabilities(for: selectedProvider) else { return [] }
      return FoundationModelsToolCatalog.makeTools(
        settings: settings.foundationModels,
        supportsVision: capabilities.contains(.vision)
      )
    }

    private var requestConfigurationMessage: String? {
      if case .failure(let error) = selection { return error.localizedDescription }
      guard readiness.canSend else { return unavailableMessage }

      if pendingImage != nil && !supportsImageInput {
        return imageUnavailableMessage
      }

      if provider == .liteRT,
        settings.liteRT.visionBackend != .disabled,
        LiteRTModelInspector.capabilities(
          for: URL(
            fileURLWithPath: LocalModelResourceIdentity.normalizedFilePath(
              settings.liteRT.modelPath))
        )?.supportsVision
          != true
      {
        return "선택한 LiteRT 모델에 호환되는 이미지 encoder가 없습니다. Vision backend를 끄거나 Vision 모델을 선택하세요."
      }

      let foundationSettings = settings.foundationModels
      if let issue = foundationSettings.validationIssue {
        switch issue {
        case .randomTopKOutOfRange:
          return "Top K는 1 이상 128 이하이어야 합니다."
        case .probabilityThresholdOutOfRange:
          return "확률 임계값은 0.01 이상 1 이하의 유한한 숫자여야 합니다."
        case .historyEntryLimitOutOfRange:
          return "History entries는 1 이상 256 이하이어야 합니다."
        case .customReasoningLevelMissing:
          return "Custom reasoning level을 입력하세요."
        case .temperatureOutOfRange:
          return "temperature는 0 이상 1 이하의 유한한 숫자여야 합니다."
        case .maximumResponseTokensOutOfRange:
          return "maximum response tokens는 1 이상이어야 합니다."
        }
      }
      if provider == .liteRT, foundationSettings.randomSeed != nil {
        return "LiteRT 어댑터는 seed를 지원하지 않습니다. seed 설정을 지우세요."
      }
      let capabilities = activeFoundationLanguageModelCapabilities

      if foundationSettings.responseMode != .text,
        capabilities?.contains(.guidedGeneration) != true
      {
        return "현재 모델이 guided generation을 지원하지 않습니다. 텍스트 응답을 선택하세요."
      }

      if foundationSettings.reasoningLevel != .none,
        capabilities?.contains(.reasoning) != true
      {
        return "현재 모델이 reasoning을 지원하지 않습니다. reasoning을 끄세요."
      }

      if foundationSettings.enabledToolCount > 0,
        capabilities?.contains(.toolCalling) != true
      {
        return "현재 모델이 tool calling을 지원하지 않습니다. 도구를 끄세요."
      }

      if foundationSettings.enabledToolCount > 0,
        foundationSettings.toolCallingMode == .disallowed
      {
        return "native 도구를 사용하려면 tool calling을 허용 또는 필수로 설정하세요."
      }

      if foundationSettings.enabledToolCount > currentTools(for: provider).count {
        return "선택한 모델이 활성화된 도구 일부를 지원하지 않습니다. 도구 설정을 확인하세요."
      }

      if foundationSettings.toolCallingMode == .required,
        foundationSettings.enabledToolCount == 0
      {
        return "tool calling을 필수로 설정하려면 하나 이상의 native 도구를 켜세요."
      }

      return nil
    }

    private var unavailableMessage: String {
      switch provider {
      case .coreAI:
        return coreAIStatus
      case .apple:
        if readiness == .unsupportedLocale {
          return "현재 macOS 언어는 Apple Intelligence에서 지원되지 않습니다. 지원 언어로 변경한 뒤 다시 시도하세요."
        }
        if AppleLocalAIModelReadiness.evaluate(systemModel) == .contextUnavailable {
          return "Apple Intelligence 모델 서비스가 아직 요청 가능한 상태가 아닙니다. 모델 준비와 약관 상태를 확인한 뒤 다시 시도하세요."
        }
        return "Apple Intelligence를 켜고 모델이 준비된 뒤 다시 시도하세요."
      case .privateCloud:
        if readiness == .quotaExceeded {
          return "Private Cloud Compute 사용량 한도에 도달했습니다. 한도 초기화를 기다리거나 사용량 제안을 확인하세요."
        }
        if readiness == .unsupportedLocale {
          return "현재 언어는 Private Cloud Compute에서 지원되지 않습니다."
        }
        return privateCloudRuntimeErrorMessage ?? "Private Cloud Compute가 준비되지 않았습니다."
      case .mlx:
        return "MLX 모델 폴더와 capability 설정을 확인한 뒤 다시 시도하세요."
      case .liteRT:
        return "LiteRT 모델 파일 경로와 백엔드를 확인한 뒤 다시 시도하세요."
      case .remote:
        return remoteCredentialErrorMessage ?? "원격 HTTPS endpoint와 모델 이름을 확인하세요."
      }
    }

    private var imageUnavailableMessage: String {
      switch provider {
      case .coreAI:
        return "현재 Core AI 모델이 이미지 입력을 지원하지 않습니다."
      case .apple, .privateCloud:
        return "현재 선택한 Foundation Models 모델은 이미지 입력을 지원하지 않습니다. Vision capability를 확인하세요."
      case .mlx:
        return "선택한 MLX 모델은 이미지 입력을 지원하지 않습니다. MLXVLM vision 모델 폴더를 선택하세요."
      case .liteRT:
        if settings.liteRT.visionBackend == .disabled {
          return "LiteRT Vision backend를 켜고 호환되는 이미지 encoder가 있는 모델을 선택하세요."
        }
        return "선택한 LiteRT 모델에 호환되는 이미지 encoder가 없습니다."
      case .remote:
        return "원격 모델이 이미지 입력을 실제 지원할 때만 Vision capability를 켜세요."
      }
    }

    private var mlxCapabilityList: [LanguageModelCapabilities.Capability] {
      mlxCapabilityList(for: LocalModelResourceIdentity.normalizedDirectoryPath(mlxModelPath))
    }

    private func mlxCapabilityList(for modelPath: String)
      -> [LanguageModelCapabilities.Capability]
    {
      var capabilities: [LanguageModelCapabilities.Capability] = []
      if !modelPath.isEmpty,
        LocalModelAsset.isMLXVLMModelDirectory(
          at: URL(fileURLWithPath: modelPath, isDirectory: true))
      {
        capabilities.append(.vision)
      }
      if settings.mlx.guidedGeneration { capabilities.append(.guidedGeneration) }
      if settings.mlx.toolCalling { capabilities.append(.toolCalling) }
      if settings.mlx.reasoning { capabilities.append(.reasoning) }
      return capabilities
    }

    private func updateSettings(_ update: (inout ProviderSettings) -> Void) {
      var updatedSettings = settings
      update(&updatedSettings)
      guard updatedSettings != settings else { return }

      let systemModelChanged =
        updatedSettings.foundationModels.useCase != settings.foundationModels.useCase
        || updatedSettings.foundationModels.guardrails != settings.foundationModels.guardrails
      let foundationSettingsChanged = updatedSettings.foundationModels != settings.foundationModels
      let routingChanged =
        updatedSettings.workload != settings.workload
        || updatedSettings.allowPrivateCloud != settings.allowPrivateCloud
        || updatedSettings.coreAIModelPath != settings.coreAIModelPath
      let providerChanged = updatedSettings.provider != settings.provider
      let mlxSettingsChanged = updatedSettings.mlx != settings.mlx
      let liteRTSettingsChanged = updatedSettings.liteRT != settings.liteRT
      let remoteSettingsChanged = updatedSettings.remote != settings.remote
      settings = updatedSettings
      settingsStore.save(updatedSettings)
      settingsPersistenceErrorMessage = settingsStore.persistenceErrorMessage

      if systemModelChanged {
        systemModel = SystemLanguageModel(
          useCase: updatedSettings.foundationModels.useCase.nativeValue,
          guardrails: updatedSettings.foundationModels.guardrails.nativeValue
        )
      }

      if routingChanged || providerChanged || foundationSettingsChanged
        || mlxSettingsChanged || liteRTSettingsChanged || remoteSettingsChanged
      {
        cancelPrewarm()
        if lifecycle.isBusy {
          // Revoke the old operation before yielding or debouncing any UI reset.
          request(.configurationChanged)
        } else {
          scheduleConfigurationReset()
        }
      }
    }

    private func resetObservations() {
      cancelTokenCount()
      usageSnapshot = FoundationModelsUsageSnapshot()
      estimatedPromptTokenCount = nil
      transcriptEntryCount = 0
      activeToolNames = []
      lastFeedbackLabel = nil
    }

    private func clearSession() {
      session = nil
      sessionConfiguration = nil
      historyEntryCountBeforeCurrentTurn = nil
      lastSelection = nil
    }

    private func apply(_ event: ConversationState.Event) {
      switch conversationState.applying(event) {
      case .success(let next):
        conversationState = next
      case .failure(let error):
        assertionFailure("Invalid conversation transition: \(error)")
      }
    }

    private func scheduleConfigurationReset() {
      configurationResetTask?.cancel()
      configurationRevision &+= 1
      let revision = configurationRevision

      configurationResetTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(nanoseconds: Policy.configurationResetDelayNanoseconds)
          guard let self, !Task.isCancelled, self.configurationRevision == revision else {
            return
          }
          self.request(.configurationChanged)
        } catch {
          // A newer edit or an explicit send superseded this reset.
        }
      }
    }

    private func scheduleNativeResourceRelease() {
      guard let previousConfiguration = sessionConfiguration else { return }
      let nextProvider = (try? selection.get().id) ?? settings.provider
      guard
        NativeModelResourcePolicy.nativeResourceNeedsRelease(
          oldProvider: previousConfiguration.selectedProvider,
          oldSettings: previousConfiguration.settings,
          newProvider: nextProvider,
          newSettings: settings
        )
      else {
        return
      }

      nativeResourceReleaseRevision &+= 1
      let revision = nativeResourceReleaseRevision
      let predecessor = nativeResourceReleaseTask
      nativeResourceReleaseTask = Task {
        @MainActor [weak self, predecessor, previousConfiguration, revision] in
        if let predecessor {
          try await predecessor.value
        }
        guard let self, !self.lifecycle.isBusy else { return }

        let ownsPreviousConfiguration = self.sessionConfiguration == previousConfiguration
        let previousSessionWasDiscarded = self.session == nil && self.sessionConfiguration == nil
        guard ownsPreviousConfiguration || previousSessionWasDiscarded else { return }

        if ownsPreviousConfiguration {
          try self.session?.clearProfile()
          self.sessionConfiguration = nil
        }
        await self.releaseNativeResources(for: previousConfiguration.selectedProvider)
        if self.nativeResourceReleaseRevision == revision {
          self.nativeResourceReleaseTask = nil
        }
      }
    }

    private func cancelConfigurationReset() {
      configurationRevision &+= 1
      configurationResetTask?.cancel()
      configurationResetTask = nil
    }

    private func cancelPrivateCloudRefresh() {
      privateCloudRevision &+= 1
      privateCloudRefreshTask?.cancel()
      privateCloudRefreshTask = nil
    }

    private func cancelPrewarm() {
      prewarmTask?.cancel()
      prewarmTask = nil
    }

    private func request(_ action: PendingResponseAction) {
      guard !lifecycle.isBusy else {
        // A configuration edit is maintenance already reflected in `settings`.
        // It must not overwrite an explicit user action that is waiting for the
        // current generation to settle. Explicit actions may replace maintenance.
        if case .configurationChanged = action, pendingAction != nil {
          // Keep the existing user-visible action.
        } else {
          pendingAction = action
        }
        beginCancellation()
        return
      }
      apply(action)
    }

    private func apply(_ action: PendingResponseAction) {
      cancelPrewarm()
      cancelConfigurationReset()
      switch action {
      case .newConversation:
        clearSession()
        resetObservations()
        prompt = ""
        pendingImage = nil
        apply(.reset)
      case .configurationChanged:
        // Preserve the native session/history across profile edits. Only the
        // selected model profile is replaced; a stale CoreAI model is detached
        // before its resources are explicitly released.
        cancelTokenCount()
        releaseCoreAIModelIfStale()
        scheduleNativeResourceRelease()
      case .retry(let submittedPrompt, let image):
        prompt = submittedPrompt
        pendingImage = image
        apply(.reset)
        respond()
      }
    }

    private func beginCancellation() {
      guard let operation = lifecycle.operation else { return }
      do {
        try lifecycle.requestCancellation(operation)
      } catch {
        return
      }

      apply(.requestCancellation)
      cancelTokenCount()
      responseTask?.cancel()

      guard let task = responseTask else {
        settleCancellation(operation)
        return
      }

      Task { @MainActor [weak self, task, operation] in
        await task.value
        self?.settleCancellation(operation)
      }
    }

    private func settleCancellation(_ operation: OperationID) {
      do {
        try lifecycle.settleCancellation(operation)
      } catch {
        return
      }
      responseTask = nil
      apply(.settleCancellation)

      guard let pendingAction else { return }
      self.pendingAction = nil
      apply(pendingAction)
    }

    func finishResponse(answer: String, operation: OperationID) {
      guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        failResponse(
          message: AppleLocalAIModelError.emptyResponse.localizedDescription, operation: operation)
        return
      }
      do {
        try lifecycle.finish(operation)
      } catch {
        return
      }
      cancelTokenCount()
      responseTask = nil
      apply(.finish(answer: answer))
      transcriptEntryCount = session?.history.count ?? transcriptEntryCount
    }

    private func failResponse(message: String, operation: OperationID) {
      do {
        try lifecycle.finish(operation)
      } catch {
        return
      }
      cancelTokenCount()
      responseTask = nil
      apply(
        .fail(
          message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "응답을 생성하지 못했습니다." : message))
      transcriptEntryCount = session?.history.count ?? transcriptEntryCount
    }

    private func updateResponse(answer: String, operation: OperationID) {
      guard lifecycle == .running(operation) else { return }
      apply(.updateAnswer(answer))
    }

    private func updateUsage(
      _ usage: LanguageModelSession.Usage,
      transcriptEntries: Int,
      session: AppleLocalAISession,
      operation: OperationID
    ) {
      guard lifecycle == .running(operation), self.session === session else { return }
      transcriptEntryCount = transcriptEntries
      // LiteRT exact counts require optional benchmark collection. This app
      // does not enable that global flag, and stream chunks are not tokens,
      // so unavailable measurements must not become application usage state.
      guard lastSelection?.id != .liteRT else {
        usageSnapshot = FoundationModelsUsageSnapshot()
        return
      }
      usageSnapshot = FoundationModelsUsageSnapshot(usage)
    }

    // Internal for deterministic identity/history regression tests.
    func makeOrReuseSession() async throws -> AppleLocalAISession {
      try Task.checkCancellation()
      if let pendingRelease = nativeResourceReleaseTask {
        let pendingRevision = nativeResourceReleaseRevision
        do {
          try await pendingRelease.value
        } catch {
          // A failed cleanup must not become a permanent failed-future gate.
          // Preserve the original cleanup error for this request, then let the
          // next request retry the release boundary from the live state.
          if nativeResourceReleaseRevision == pendingRevision {
            nativeResourceReleaseTask = nil
          }
          throw error
        }
        if nativeResourceReleaseRevision == pendingRevision {
          nativeResourceReleaseTask = nil
        }
        try Task.checkCancellation()
      }
      let decision = try selection.get()
      let runtimeSettings = NativeModelResourcePolicy.runtimeSettingsSnapshot(settings)
      let configuration = SessionConfiguration(
        settings: runtimeSettings,
        selectedProvider: decision.id,
        remoteCredentialRevision: decision.id == .remote ? remoteCredentialRevision : 0
      )
      if let session, sessionConfiguration == configuration {
        lastSelection = decision
        return session
      }

      var releasedPreviousNativeResources = false
      if let previousConfiguration = sessionConfiguration,
        NativeModelResourcePolicy.nativeResourceNeedsRelease(
          oldProvider: previousConfiguration.selectedProvider,
          oldSettings: previousConfiguration.settings,
          newProvider: decision.id,
          newSettings: settings
        )
      {
        try session?.clearProfile()
        sessionConfiguration = nil
        await releaseNativeResources(for: previousConfiguration.selectedProvider)
        releasedPreviousNativeResources = true
        try Task.checkCancellation()
      }

      do {
        let model: any LanguageModel
        let instructions: String
        switch decision.id {
        case .apple, .privateCloud:
          model = try makeNativeFoundationModel(for: decision.id)
          instructions = LocalAIInstructions.system
        case .coreAI:
          guard coreAIModelMatchesConfiguredPath, let loaded = coreAIModel else {
            throw ModelSelectionError.noEligibleModel
          }
          model = loaded
          instructions = LocalAIInstructions.system
        case .liteRT:
          model = try LocalLanguageModels.liteRT(settings: runtimeSettings.liteRT)
          instructions = LocalAIInstructions.liteRT(
            modelName: runtimeSettings.liteRT.modelIdentifier)
        case .mlx:
          guard mlxModelPathIsValid else { throw ModelSelectionError.noEligibleModel }
          let directory = URL(
            fileURLWithPath: runtimeSettings.mlx.modelPath, isDirectory: true)
          model = try LocalLanguageModels.mlx(
            directory: directory,
            capabilities: mlxCapabilityList(for: runtimeSettings.mlx.modelPath))
          instructions = LocalAIInstructions.system
        case .remote:
          model = try makeRemoteLanguageModel()
          instructions = LocalAIInstructions.remote(modelName: settings.remote.modelName)
        }
        try Task.checkCancellation()
        // Validate the actual loaded model too; advertised metadata is only a preflight.
        var required = taskRequirements
        if workload == .deepReasoning { required.insert(.reasoning) }
        var actualCapabilities = requirements(model.capabilities)
        if decision.id == .remote {
          actualCapabilities.formIntersection(requirements(remoteCapabilities))
        }
        guard required.isSubset(of: actualCapabilities) else {
          throw ModelSelectionError.noEligibleModel
        }
        let tools = currentTools(for: decision.id)
        var profileSettings = settings.foundationModels
        if workload == .deepReasoning, profileSettings.reasoningLevel == .none {
          profileSettings.reasoningLevel = .deep
        }
        let profile = try AppleLocalAIProfile(
          model: model,
          instructions: instructions,
          tools: tools,
          temperature: profileSettings.temperature,
          samplingMode: profileSettings.nativeSamplingMode,
          maximumResponseTokens: profileSettings.maximumResponseTokens,
          reasoningLevel: profileSettings.nativeReasoningLevel,
          toolCallingMode: profileSettings.nativeToolCallingMode,
          historyPolicy: .recentEntries(profileSettings.historyEntryLimit)
        )
        let canonicalSession: AppleLocalAISession
        if let session {
          try session.reconfigure(profile)
          canonicalSession = session
        } else {
          canonicalSession = AppleLocalAISession(profile: profile)
        }
        session = canonicalSession
        sessionConfiguration = configuration
        activeToolNames = tools.map(\.name)
        lastSelection = decision
        return canonicalSession
      } catch {
        // A failed replacement must not leave a newly constructed local cache
        // behind after the previous profile has already been detached. Preserve
        // the primary construction/cancellation error; cache release is a
        // non-throwing settlement boundary.
        if releasedPreviousNativeResources {
          switch decision.id {
          case .mlx, .liteRT:
            await releaseNativeResources(for: decision.id)
          case .coreAI, .apple, .privateCloud, .remote:
            break
          }
        }
        throw error
      }
    }

    private func releaseNativeResources(for provider: LocalProviderChoice) async {
      switch provider {
      case .mlx:
        await LocalLanguageModels.releaseMLXResources()
      case .liteRT:
        await LocalLanguageModels.releaseLiteRTResources()
      case .coreAI, .apple, .privateCloud, .remote:
        break
      }
    }

    private func makeNativeFoundationModel(for selectedProvider: LocalProviderChoice) throws
      -> any LanguageModel
    {
      switch selectedProvider {
      case .apple:
        switch AppleLocalAIModelReadiness.evaluate(systemModel) {
        case .ready:
          return systemModel
        case .unsupportedLocale:
          throw AppleLocalAIModelError.unsupportedLocale
        case .unavailable, .contextUnavailable:
          throw AppleLocalAIModelError.appleIntelligenceUnavailable
        }
      case .privateCloud:
        guard case .available = privateCloudModel.availability else {
          throw AppleLocalAIModelError.privateCloudUnavailable
        }
        guard !privateCloudModel.quotaUsage.isLimitReached else {
          throw AppleLocalAIModelError.privateCloudQuotaExceeded
        }
        guard privateCloudLocaleSupport() else {
          throw AppleLocalAIModelError.unsupportedLocale
        }
        return privateCloudModel
      case .mlx, .liteRT, .coreAI, .remote:
        throw ModelSelectionError.noEligibleModel
      }
    }

    private func privateCloudLocaleSupport() -> Bool {
      if let supportsCurrentLocale = privateCloudRuntime.supportsCurrentLocale {
        return supportsCurrentLocale
      }
      return false
    }

    static func addingTokenCount(_ total: Int, _ next: Int) -> Int? {
      guard total >= 0, next >= 0 else { return nil }
      let result = total.addingReportingOverflow(next)
      return result.overflow ? nil : result.partialValue
    }

    private func estimatedPromptTokenCountTask(
      session: AppleLocalAISession,
      request: AppleLocalAIRequest,
      schema: GenerationSchema?,
      tools: [any Tool],
      provider: LocalProviderChoice,
      operation: OperationID
    ) {
      cancelTokenCount()
      guard provider == .apple else { return }
      let instructions = Instructions(LocalAIInstructions.system)
      let currentSession = session
      // Capture the model's pre-request view before either async task can append
      // the new prompt. Instructions are counted separately above, never twice.
      let history = currentSession.history.filter {
        if case .instructions = $0 { false } else { true }
      }
      tokenCountOperation = operation
      tokenCountTask = Task {
        @MainActor [
          weak self, currentSession, request, schema, tools, instructions, history,
          operation
        ]
        in
        defer {
          if let self, self.tokenCountOperation == operation {
            self.tokenCountTask = nil
            self.tokenCountOperation = nil
          }
        }
        do {
          var total = try await currentSession.tokenCount(for: request)
          guard total >= 0 else { return }
          let instructionCount = try await currentSession.tokenCount(for: instructions)
          guard let next = Self.addingTokenCount(total, instructionCount) else { return }
          total = next
          if !tools.isEmpty {
            let toolCount = try await currentSession.tokenCount(for: tools)
            guard let next = Self.addingTokenCount(total, toolCount) else { return }
            total = next
          }
          if let schema {
            let schemaCount = try await currentSession.tokenCount(for: schema)
            guard let next = Self.addingTokenCount(total, schemaCount) else { return }
            total = next
          }
          if !history.isEmpty {
            let historyCount = try await currentSession.tokenCount(for: history)
            guard let next = Self.addingTokenCount(total, historyCount) else { return }
            total = next
          }
          guard let self,
            self.lifecycle == .running(operation),
            self.session === currentSession
          else {
            return
          }
          self.estimatedPromptTokenCount = total
        } catch {
          // PCC intentionally has no synthetic token estimate; System model
          // token-count failures remain an unavailable diagnostic only.
        }
      }
    }

    private func cancelTokenCount() {
      tokenCountTask?.cancel()
      tokenCountTask = nil
      tokenCountOperation = nil
    }

    private func makeRequest(text: String, image: ConversationImage?) throws
      -> AppleLocalAIRequest
    {
      let textInput = try AppleLocalAITextInput(text)
      guard let image else {
        return AppleLocalAITextRequest(text: textInput).makeRequest()
      }
      let imageInput = try AppleLocalAIImageInput(url: image.url, label: "user-image")
      return try AppleLocalAIVisionRequest(text: textInput, image: imageInput).makeRequest()
    }

    private static func privateCloudSnapshot(
      availabilityLabel: String,
      isAvailable: Bool,
      quota: PrivateCloudComputeLanguageModel.QuotaUsage?,
      supportsCurrentLocale: Bool?,
      contextSize: Int?,
      languageCount: Int?,
      errorMessage: String?
    ) -> PrivateCloudRuntimeSnapshot {
      PrivateCloudRuntimeSnapshot(
        isChecking: false,
        availabilityLabel: availabilityLabel,
        isAvailable: isAvailable,
        quotaLimitReached: quota?.isLimitReached ?? false,
        quotaResetDate: quota?.resetDate,
        supportsCurrentLocale: supportsCurrentLocale,
        contextSize: contextSize,
        languageCount: languageCount,
        errorMessage: errorMessage
      )
    }
  }

  private struct SessionConfiguration: Equatable, Sendable {
    let settings: ProviderSettings
    let selectedProvider: LocalProviderChoice
    let remoteCredentialRevision: UInt64
  }

  private enum PendingResponseAction: Equatable, Sendable {
    case newConversation
    case configurationChanged
    case retry(prompt: String, image: ConversationImage?)
  }

#endif
