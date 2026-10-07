#if os(macOS)
  import AppleLocalAIFoundationModels
  import Foundation
  import Testing

  @Suite("Foundation Models settings contract")
  struct FoundationModelsSettingsTests {
    @Test func standardSettingsAreValid() {
      #expect(FoundationModelsSettings.standard.validationIssue == nil)
    }

    @Test(arguments: ["{}", #"{"responseMode":null,"historyEntryLimit":null,"randomSeed":null}"#])
    func missingAndNullFieldsRetainStandardDefaults(_ json: String) throws {
      let decoded = try JSONDecoder().decode(
        FoundationModelsSettings.self, from: Data(json.utf8))
      #expect(decoded == .standard)
    }

    @Test func partialSettingsPreserveValuesAndDefaultOnlyMissingFields() throws {
      let json =
        #"{"historyEntryLimit":12,"includeSchemaInPrompt":false,"enableOCRTool":true,"temperature":0.25}"#
      var expected = FoundationModelsSettings.standard
      expected.historyEntryLimit = 12
      expected.includeSchemaInPrompt = false
      expected.enableOCRTool = true
      expected.temperature = 0.25

      let decoded = try JSONDecoder().decode(
        FoundationModelsSettings.self, from: Data(json.utf8))
      #expect(decoded == expected)
    }

    @Test(arguments: [#"{"historyEntryLimit":"12"}"#, #"{"responseMode":"future-mode"}"#])
    func invalidStoredValuesAreNotReplacedWithDefaults(_ json: String) {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(FoundationModelsSettings.self, from: Data(json.utf8))
      }
    }

    @Test func customizedSettingsRoundTripWithoutChangingStoredValues() throws {
      var settings = FoundationModelsSettings.standard
      settings.historyEntryLimit = 12
      settings.randomSeed = 42
      settings.temperature = 0.25
      settings.maximumResponseTokens = 256
      settings.includeSchemaInPrompt = false
      settings.enableOCRTool = true
      settings.enableSpotlightSearchTool = true

      let encoded = try JSONEncoder().encode(settings)
      #expect(try JSONDecoder().decode(FoundationModelsSettings.self, from: encoded) == settings)
      var stored = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      #expect(stored["transcriptPolicy"] == nil)
      stored["transcriptPolicy"] = "revert"
      let previous = try JSONSerialization.data(withJSONObject: stored)
      #expect(try JSONDecoder().decode(FoundationModelsSettings.self, from: previous) == settings)
    }

    @Test func selectedTopKIsRejectedInsteadOfClamped() {
      var settings = FoundationModelsSettings.standard
      settings.samplingMode = .randomTopK
      settings.randomTopK = FoundationModelsSettings.minimumRandomTopK - 1

      #expect(settings.validationIssue == .randomTopKOutOfRange)
    }

    @Test func selectedProbabilityThresholdIsRejectedInsteadOfClamped() {
      var settings = FoundationModelsSettings.standard
      settings.samplingMode = .randomProbabilityThreshold
      settings.probabilityThreshold = .nan

      #expect(settings.validationIssue == .probabilityThresholdOutOfRange)
    }

    @Test func historyLimitIsRejectedInsteadOfClamped() {
      var settings = FoundationModelsSettings.standard
      settings.historyEntryLimit = FoundationModelsSettings.maximumHistoryEntryLimit + 1

      #expect(settings.validationIssue == .historyEntryLimitOutOfRange)
    }

    @Test func inactiveSamplingFieldsDoNotInvalidateGreedyMode() {
      var settings = FoundationModelsSettings.standard
      settings.randomTopK = 0
      settings.probabilityThreshold = .infinity

      #expect(settings.validationIssue == nil)
    }

    @Test func customReasoningRequiresNonEmptyText() {
      var settings = FoundationModelsSettings.standard
      settings.reasoningLevel = .custom
      settings.customReasoningLevel = " \n"

      #expect(settings.validationIssue == .customReasoningLevelMissing)
    }

    @Test func temperatureUsesTheSharedGenerationPolicy() {
      var settings = FoundationModelsSettings.standard
      settings.temperature = .infinity

      #expect(settings.validationIssue == .temperatureOutOfRange)
    }

    @Test func maximumResponseTokensMustBePositive() {
      var settings = FoundationModelsSettings.standard
      settings.maximumResponseTokens = 0

      #expect(settings.validationIssue == .maximumResponseTokensOutOfRange)
    }
  }
#endif
