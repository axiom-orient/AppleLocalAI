#if os(macOS)
  import AppleLocalAIHost
  import Foundation
  import FoundationModels

  package enum FoundationModelUseCase: String, CaseIterable, Codable, Equatable, Sendable {
    case general
    case contentTagging = "content-tagging"

    package var title: String {
      switch self {
      case .general:
        return "일반"
      case .contentTagging:
        return "콘텐츠 태깅"
      }
    }

    package var nativeValue: SystemLanguageModel.UseCase {
      switch self {
      case .general:
        return .general
      case .contentTagging:
        return .contentTagging
      }
    }
  }

  package enum FoundationModelGuardrails: String, CaseIterable, Codable, Equatable, Sendable {
    case `default`
    case permissiveContentTransformations = "permissive-content-transformations"

    package var title: String {
      switch self {
      case .default:
        return "기본"
      case .permissiveContentTransformations:
        return "콘텐츠 변환 완화"
      }
    }

    package var nativeValue: SystemLanguageModel.Guardrails {
      switch self {
      case .default:
        return .default
      case .permissiveContentTransformations:
        return .permissiveContentTransformations
      }
    }
  }

  package enum FoundationModelResponseMode: String, CaseIterable, Codable, Equatable, Sendable {
    case text
    case typed
    case dynamicSchema = "dynamic-schema"

    package var title: String {
      switch self {
      case .text:
        return "텍스트"
      case .typed:
        return "Generable 구조체"
      case .dynamicSchema:
        return "동적 스키마"
      }
    }

    package var subtitle: String {
      switch self {
      case .text:
        return "일반 스트리밍 응답"
      case .typed:
        return "Swift 타입으로 검증"
      case .dynamicSchema:
        return "런타임 GenerationSchema"
      }
    }
  }

  package enum FoundationModelSamplingMode: String, CaseIterable, Codable, Equatable, Sendable {
    case greedy
    case randomTopK = "random-top-k"
    case randomProbabilityThreshold = "random-probability-threshold"

    package var title: String {
      switch self {
      case .greedy:
        return "Greedy"
      case .randomTopK:
        return "Random · Top K"
      case .randomProbabilityThreshold:
        return "Random · 확률 임계값"
      }
    }
  }

  package enum FoundationModelsSettingsValidationIssue: Equatable, Sendable {
    case randomTopKOutOfRange
    case probabilityThresholdOutOfRange
    case historyEntryLimitOutOfRange
    case customReasoningLevelMissing
    case temperatureOutOfRange
    case maximumResponseTokensOutOfRange
  }

  package enum FoundationModelReasoningLevel: String, CaseIterable, Codable, Equatable, Sendable {
    case none
    case light
    case moderate
    case deep
    case custom

    package var title: String {
      switch self {
      case .none:
        return "사용 안 함"
      case .light:
        return "Light"
      case .moderate:
        return "Moderate"
      case .deep:
        return "Deep"
      case .custom:
        return "Custom"
      }
    }

    package func nativeValue(customText: String) -> ContextOptions.ReasoningLevel? {
      switch self {
      case .none:
        return nil
      case .light:
        return .light
      case .moderate:
        return .moderate
      case .deep:
        return .deep
      case .custom:
        let normalized = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : .custom(normalized)
      }
    }
  }

  package enum FoundationModelToolCallingMode: String, CaseIterable, Codable, Equatable, Sendable {
    case disallowed
    case allowed
    case required

    package var title: String {
      switch self {
      case .disallowed:
        return "사용 안 함"
      case .allowed:
        return "허용"
      case .required:
        return "필수"
      }
    }

    package var nativeValue: GenerationOptions.ToolCallingMode {
      switch self {
      case .disallowed:
        return .disallowed
      case .allowed:
        return .allowed
      case .required:
        return .required
      }
    }
  }

  package enum FoundationModelTranscriptPolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case revert
    case preserve

    package var title: String {
      switch self {
      case .revert:
        return "실패 시 되돌리기"
      case .preserve:
        return "실패한 transcript 보존"
      }
    }

    package var nativeValue: TranscriptErrorHandlingPolicy {
      switch self {
      case .revert:
        return .revertTranscript
      case .preserve:
        return .preserveTranscript
      }
    }
  }

  package struct FoundationModelsSettings: Codable, Equatable, Sendable {
    package static let minimumRandomTopK = 1
    package static let maximumRandomTopK = 128
    package static let minimumProbabilityThreshold = GenerationPolicy.minimumProbabilityThreshold
    package static let maximumProbabilityThreshold = GenerationPolicy.maximumProbabilityThreshold
    package static let minimumHistoryEntryLimit = 1
    package static let maximumHistoryEntryLimit = 256

    package var useCase: FoundationModelUseCase
    package var guardrails: FoundationModelGuardrails
    package var responseMode: FoundationModelResponseMode
    package var samplingMode: FoundationModelSamplingMode
    package var randomTopK: Int
    package var probabilityThreshold: Double
    package var randomSeed: UInt64?
    package var temperature: Double?
    package var maximumResponseTokens: Int?
    package var reasoningLevel: FoundationModelReasoningLevel
    package var customReasoningLevel: String
    package var toolCallingMode: FoundationModelToolCallingMode
    package var includeSchemaInPrompt: Bool
    package var historyEntryLimit: Int
    package var transcriptPolicy: FoundationModelTranscriptPolicy
    package var enableOCRTool: Bool
    package var enableBarcodeReaderTool: Bool
    package var enableImageMetadataTool: Bool
    package var enableSpotlightSearchTool: Bool

    private enum CodingKeys: String, CodingKey {
      case useCase
      case guardrails
      case responseMode
      case samplingMode
      case randomTopK
      case probabilityThreshold
      case randomSeed
      case temperature
      case maximumResponseTokens
      case reasoningLevel
      case customReasoningLevel
      case toolCallingMode
      case includeSchemaInPrompt
      case historyEntryLimit
      case transcriptPolicy
      case enableOCRTool
      case enableBarcodeReaderTool
      case enableImageMetadataTool
      case enableSpotlightSearchTool
    }

    package static let standard = Self(
      useCase: .general,
      guardrails: .default,
      responseMode: .text,
      samplingMode: .greedy,
      randomTopK: 8,
      probabilityThreshold: 0.95,
      randomSeed: nil,
      temperature: nil,
      maximumResponseTokens: nil,
      reasoningLevel: .none,
      customReasoningLevel: "",
      toolCallingMode: .disallowed,
      includeSchemaInPrompt: true,
      historyEntryLimit: 48,
      transcriptPolicy: .revert,
      enableOCRTool: false,
      enableBarcodeReaderTool: false,
      enableImageMetadataTool: false,
      enableSpotlightSearchTool: false
    )

    package init(
      useCase: FoundationModelUseCase,
      guardrails: FoundationModelGuardrails,
      responseMode: FoundationModelResponseMode,
      samplingMode: FoundationModelSamplingMode,
      randomTopK: Int,
      probabilityThreshold: Double,
      randomSeed: UInt64?,
      temperature: Double?,
      maximumResponseTokens: Int?,
      reasoningLevel: FoundationModelReasoningLevel,
      customReasoningLevel: String,
      toolCallingMode: FoundationModelToolCallingMode,
      includeSchemaInPrompt: Bool,
      historyEntryLimit: Int,
      transcriptPolicy: FoundationModelTranscriptPolicy,
      enableOCRTool: Bool,
      enableBarcodeReaderTool: Bool,
      enableImageMetadataTool: Bool,
      enableSpotlightSearchTool: Bool
    ) {
      self.useCase = useCase
      self.guardrails = guardrails
      self.responseMode = responseMode
      self.samplingMode = samplingMode
      self.randomTopK = randomTopK
      self.probabilityThreshold = probabilityThreshold
      self.randomSeed = randomSeed
      self.temperature = temperature
      self.maximumResponseTokens = maximumResponseTokens
      self.reasoningLevel = reasoningLevel
      self.customReasoningLevel = customReasoningLevel
      self.toolCallingMode = toolCallingMode
      self.includeSchemaInPrompt = includeSchemaInPrompt
      self.historyEntryLimit = historyEntryLimit
      self.transcriptPolicy = transcriptPolicy
      self.enableOCRTool = enableOCRTool
      self.enableBarcodeReaderTool = enableBarcodeReaderTool
      self.enableImageMetadataTool = enableImageMetadataTool
      self.enableSpotlightSearchTool = enableSpotlightSearchTool
    }

    package init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let defaults = Self.standard
      useCase =
        try container.decodeIfPresent(FoundationModelUseCase.self, forKey: .useCase)
        ?? defaults.useCase
      guardrails =
        try container.decodeIfPresent(FoundationModelGuardrails.self, forKey: .guardrails)
        ?? defaults.guardrails
      responseMode =
        try container.decodeIfPresent(FoundationModelResponseMode.self, forKey: .responseMode)
        ?? defaults.responseMode
      samplingMode =
        try container.decodeIfPresent(FoundationModelSamplingMode.self, forKey: .samplingMode)
        ?? defaults.samplingMode
      randomTopK =
        try container.decodeIfPresent(Int.self, forKey: .randomTopK) ?? defaults.randomTopK
      probabilityThreshold =
        try container.decodeIfPresent(Double.self, forKey: .probabilityThreshold)
        ?? defaults.probabilityThreshold
      randomSeed = try container.decodeIfPresent(UInt64.self, forKey: .randomSeed)
      temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
      maximumResponseTokens = try container.decodeIfPresent(
        Int.self, forKey: .maximumResponseTokens)
      reasoningLevel =
        try container.decodeIfPresent(FoundationModelReasoningLevel.self, forKey: .reasoningLevel)
        ?? defaults.reasoningLevel
      customReasoningLevel =
        try container.decodeIfPresent(String.self, forKey: .customReasoningLevel)
        ?? defaults.customReasoningLevel
      toolCallingMode =
        try container.decodeIfPresent(FoundationModelToolCallingMode.self, forKey: .toolCallingMode)
        ?? defaults.toolCallingMode
      includeSchemaInPrompt =
        try container.decodeIfPresent(Bool.self, forKey: .includeSchemaInPrompt)
        ?? defaults.includeSchemaInPrompt
      historyEntryLimit =
        try container.decodeIfPresent(Int.self, forKey: .historyEntryLimit)
        ?? defaults.historyEntryLimit
      transcriptPolicy =
        try container.decodeIfPresent(
          FoundationModelTranscriptPolicy.self, forKey: .transcriptPolicy)
        ?? defaults.transcriptPolicy
      enableOCRTool =
        try container.decodeIfPresent(Bool.self, forKey: .enableOCRTool) ?? defaults.enableOCRTool
      enableBarcodeReaderTool =
        try container.decodeIfPresent(Bool.self, forKey: .enableBarcodeReaderTool)
        ?? defaults.enableBarcodeReaderTool
      enableImageMetadataTool =
        try container.decodeIfPresent(Bool.self, forKey: .enableImageMetadataTool)
        ?? defaults.enableImageMetadataTool
      enableSpotlightSearchTool =
        try container.decodeIfPresent(Bool.self, forKey: .enableSpotlightSearchTool)
        ?? defaults.enableSpotlightSearchTool
    }

    package func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(useCase, forKey: .useCase)
      try container.encode(guardrails, forKey: .guardrails)
      try container.encode(responseMode, forKey: .responseMode)
      try container.encode(samplingMode, forKey: .samplingMode)
      try container.encode(randomTopK, forKey: .randomTopK)
      try container.encode(probabilityThreshold, forKey: .probabilityThreshold)
      try container.encodeIfPresent(randomSeed, forKey: .randomSeed)
      try container.encodeIfPresent(temperature, forKey: .temperature)
      try container.encodeIfPresent(maximumResponseTokens, forKey: .maximumResponseTokens)
      try container.encode(reasoningLevel, forKey: .reasoningLevel)
      try container.encode(customReasoningLevel, forKey: .customReasoningLevel)
      try container.encode(toolCallingMode, forKey: .toolCallingMode)
      try container.encode(includeSchemaInPrompt, forKey: .includeSchemaInPrompt)
      try container.encode(historyEntryLimit, forKey: .historyEntryLimit)
      try container.encode(transcriptPolicy, forKey: .transcriptPolicy)
      try container.encode(enableOCRTool, forKey: .enableOCRTool)
      try container.encode(enableBarcodeReaderTool, forKey: .enableBarcodeReaderTool)
      try container.encode(enableImageMetadataTool, forKey: .enableImageMetadataTool)
      try container.encode(enableSpotlightSearchTool, forKey: .enableSpotlightSearchTool)
    }

    package var nativeSamplingMode: GenerationOptions.SamplingMode {
      switch samplingMode {
      case .greedy:
        return .greedy
      case .randomTopK:
        return .random(top: randomTopK, seed: randomSeed)
      case .randomProbabilityThreshold:
        return .random(probabilityThreshold: probabilityThreshold, seed: randomSeed)
      }
    }

    package var validationIssue: FoundationModelsSettingsValidationIssue? {
      switch samplingMode {
      case .greedy:
        break
      case .randomTopK:
        guard (Self.minimumRandomTopK...Self.maximumRandomTopK).contains(randomTopK) else {
          return .randomTopKOutOfRange
        }
      case .randomProbabilityThreshold:
        guard probabilityThreshold.isFinite,
          (Self.minimumProbabilityThreshold...Self.maximumProbabilityThreshold).contains(
            probabilityThreshold)
        else {
          return .probabilityThresholdOutOfRange
        }
      }

      guard
        (Self.minimumHistoryEntryLimit...Self.maximumHistoryEntryLimit).contains(
          historyEntryLimit)
      else {
        return .historyEntryLimitOutOfRange
      }
      if reasoningLevel == .custom,
        customReasoningLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return .customReasoningLevelMissing
      }
      if let temperature, !GenerationPolicy.acceptsTemperature(temperature) {
        return .temperatureOutOfRange
      }
      if let maximumResponseTokens, maximumResponseTokens <= 0 {
        return .maximumResponseTokensOutOfRange
      }
      return nil
    }

    package var nativeGenerationOptions: GenerationOptions {
      GenerationOptions(
        samplingMode: nativeSamplingMode,
        temperature: temperature,
        maximumResponseTokens: nativeMaximumResponseTokens,
        toolCallingMode: nativeToolCallingMode
      )
    }

    package var nativeContextOptions: ContextOptions {
      ContextOptions(
        includeSchemaInPrompt: includeSchemaInPrompt,
        reasoningLevel: nativeReasoningLevel
      )
    }

    package var nativeReasoningLevel: ContextOptions.ReasoningLevel? {
      reasoningLevel.nativeValue(customText: customReasoningLevel)
    }

    package var nativeHistoryEntryLimit: Int { historyEntryLimit }

    package var nativeMaximumResponseTokens: Int? { maximumResponseTokens }

    package var enabledToolCount: Int {
      [enableOCRTool, enableBarcodeReaderTool, enableImageMetadataTool, enableSpotlightSearchTool]
        .filter { $0 }
        .count
    }

    package var nativeToolCallingMode: GenerationOptions.ToolCallingMode? {
      guard toolCallingMode != .disallowed || enabledToolCount > 0 else {
        return .disallowed
      }
      return toolCallingMode.nativeValue
    }

  }

#endif
