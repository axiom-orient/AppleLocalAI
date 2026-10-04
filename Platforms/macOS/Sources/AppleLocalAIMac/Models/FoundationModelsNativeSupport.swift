#if os(macOS)

  import AppleLocalAIHost
  import AppleLocalAI
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels
  import FoundationModelsUtilities
  import CoreSpotlight
  import OSLog

  enum FoundationModelCapability: String, CaseIterable, Codable, Equatable, Sendable {
    case vision
    case guidedGeneration = "guided-generation"
    case reasoning
    case toolCalling = "tool-calling"

    var title: String {
      switch self {
      case .vision:
        return "Vision"
      case .guidedGeneration:
        return "Guided generation"
      case .reasoning:
        return "Reasoning"
      case .toolCalling:
        return "Tool calling"
      }
    }

    var nativeValue: LanguageModelCapabilities.Capability {
      switch self {
      case .vision:
        return .vision
      case .guidedGeneration:
        return .guidedGeneration
      case .reasoning:
        return .reasoning
      case .toolCalling:
        return .toolCalling
      }
    }
  }

  enum FoundationModelsFeedbackIssueCategory: String, CaseIterable, Codable, Equatable, Sendable {
    case unhelpful
    case tooVerbose = "too-verbose"
    case didNotFollowInstructions = "did-not-follow-instructions"
    case incorrect
    case stereotypeOrBias = "stereotype-or-bias"
    case suggestiveOrSexual = "suggestive-or-sexual"
    case vulgarOrOffensive = "vulgar-or-offensive"
    case triggeredGuardrailUnexpectedly = "triggered-guardrail-unexpectedly"

    var title: String {
      switch self {
      case .unhelpful:
        return "도움이 되지 않음"
      case .tooVerbose:
        return "너무 장황함"
      case .didNotFollowInstructions:
        return "지시를 따르지 않음"
      case .incorrect:
        return "내용이 부정확함"
      case .stereotypeOrBias:
        return "고정관념 또는 편견"
      case .suggestiveOrSexual:
        return "선정적 또는 성적 내용"
      case .vulgarOrOffensive:
        return "저속하거나 공격적임"
      case .triggeredGuardrailUnexpectedly:
        return "예상치 못한 guardrail"
      }
    }

    var nativeValue: LanguageModelFeedback.Issue.Category {
      switch self {
      case .unhelpful:
        return .unhelpful
      case .tooVerbose:
        return .tooVerbose
      case .didNotFollowInstructions:
        return .didNotFollowInstructions
      case .incorrect:
        return .incorrect
      case .stereotypeOrBias:
        return .stereotypeOrBias
      case .suggestiveOrSexual:
        return .suggestiveOrSexual
      case .vulgarOrOffensive:
        return .vulgarOrOffensive
      case .triggeredGuardrailUnexpectedly:
        return .triggeredGuardrailUnexpectedly
      }
    }
  }

  enum FoundationModelsToolCatalog {
    static func makeTools(
      settings: FoundationModelsSettings,
      supportsVision: Bool
    ) -> [any Tool] {
      guard settings.toolCallingMode != .disallowed else { return [] }

      var tools: [any Tool] = []
      if supportsVision {
        tools.append(
          contentsOf: AppleLocalAITools.vision(
            ocr: settings.enableOCRTool,
            barcode: settings.enableBarcodeReaderTool,
            imageMetadata: settings.enableImageMetadataTool
          )
        )
      }
      if settings.enableSpotlightSearchTool {
        tools.append(
          SpotlightSearchTool(
            configuration: .init(sources: [.coreSpotlight])
          )
        )
      }
      return tools
    }
  }

  struct FoundationModelsUsageSnapshot: Equatable, Sendable {
    var inputTokenCount = 0
    var cachedInputTokenCount = 0
    var outputTokenCount = 0
    var reasoningTokenCount = 0

    var totalTokenCount: Int? {
      let result = inputTokenCount.addingReportingOverflow(outputTokenCount)
      return result.overflow ? nil : result.partialValue
    }

    var isValid: Bool {
      guard inputTokenCount >= 0,
        cachedInputTokenCount >= 0,
        outputTokenCount >= 0,
        reasoningTokenCount >= 0,
        cachedInputTokenCount <= inputTokenCount,
        reasoningTokenCount <= outputTokenCount
      else {
        return false
      }
      return totalTokenCount != nil
    }

    var description: String {
      "입력 \(inputTokenCount) · 캐시 \(cachedInputTokenCount) · 출력 \(outputTokenCount) · 추론 \(reasoningTokenCount)"
    }

    init() {}

    init(_ usage: LanguageModelSession.Usage) {
      inputTokenCount = usage.input.totalTokenCount
      cachedInputTokenCount = usage.input.cachedTokenCount
      outputTokenCount = usage.output.totalTokenCount
      reasoningTokenCount = usage.output.reasoningTokenCount
    }
  }

  struct PrivateCloudRuntimeSnapshot: Equatable, Sendable {
    var isChecking = true
    var availabilityLabel = "상태 확인 중"
    var isAvailable = false
    var quotaLimitReached = false
    var quotaResetDate: Date?
    var supportsCurrentLocale: Bool?
    var contextSize: Int?
    var languageCount: Int?
    var errorMessage: String?

    var readiness: LocalAIProviderReadiness {
      if isChecking { return .checking }
      guard isAvailable, errorMessage == nil else { return .unavailable }
      if quotaLimitReached { return .quotaExceeded }
      guard let supportsCurrentLocale else { return .unavailable }
      return supportsCurrentLocale ? .ready : .unsupportedLocale
    }

    static let checking = Self()
  }

#endif
