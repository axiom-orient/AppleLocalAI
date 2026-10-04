import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAI

@Test func textAndVisionRequestsKeepInputsSeparate() throws {
  let text = try AppleLocalAITextInput("  describe this image  ")
  let image = try AppleLocalAIImageInput(
    url: URL(fileURLWithPath: "/tmp/apple-local-ai-image.png"),
    label: "reference"
  )
  let vision = AppleLocalAIVisionRequest(text: text, image: image)
  let request = try vision.makeRequest()

  #expect(text.value == "describe this image")
  #expect(vision.image.url == image.url)
  #expect(vision.image.label == "reference")
  _ = request.prompt
}

@Test func textEntrypointsShareTheCorePromptNormalizationRule() throws {
  let input = try AppleLocalAITextInput("  summarize this  ")
  #expect(input.value == "summarize this")
  _ = try AppleLocalAIRequest(text: "  summarize this  ")

  for value in ["", "  \n "] {
    #expect(throws: AppleLocalAIError.emptyPrompt) { _ = try AppleLocalAITextInput(value) }
    #expect(throws: AppleLocalAIError.emptyPrompt) { _ = try AppleLocalAIRequest(text: value) }
  }
}

@Test func rejectsNonFileImageInput() {
  #expect(throws: AppleLocalAIError.invalidImageInput) {
    _ = try AppleLocalAIImageInput(url: URL(string: "https://example.com/image.png")!)
  }
}

@Test func directVisionRequestRejectsNonFileImageURL() {
  #expect(throws: AppleLocalAIError.invalidImageInput) {
    _ = try AppleLocalAIRequest(
      text: "Describe this image",
      imageURL: URL(string: "https://example.com/image.png")!
    )
  }
}

@Test func imageLabelsNormalizeWhitespaceAndEmptyValues() throws {
  let url = URL(fileURLWithPath: "/tmp/apple-local-ai-image.png")
  #expect(try AppleLocalAIImageInput(url: url, label: "  reference  ").label == "reference")
  #expect(try AppleLocalAIImageInput(url: url, label: " \n ").label == nil)
  #expect(try AppleLocalAIImageInput(url: url).label == nil)

  for label: String? in [nil, " \n ", "  reference  "] {
    _ = try AppleLocalAIRequest(text: "Describe this image", imageURL: url, imageLabel: label)
  }
}

@Test func rejectsRequiredToolsWhenToolListIsEmpty() {
  #expect(throws: AppleLocalAIError.requiredToolCallingWithoutTools) {
    _ = try AppleLocalAIProfile(toolCallingMode: .required)
  }
}

@Test func rejectsNonPositiveHistoryLimit() {
  #expect(throws: AppleLocalAIError.invalidHistoryLimit) {
    _ = try AppleLocalAIProfile(historyPolicy: .recentEntries(0))
  }
}

@Test func rejectsNonPositiveMaximumResponseTokens() {
  for value in [0, -1] {
    #expect(throws: AppleLocalAIError.invalidMaximumResponseTokens) {
      _ = try AppleLocalAIProfile(maximumResponseTokens: value)
    }
  }
}

@Test func rejectsInvalidTemperature() {
  for value in [-0.01, 1.01, .nan, .infinity] {
    #expect(throws: AppleLocalAIError.invalidTemperature) {
      _ = try AppleLocalAIProfile(temperature: value)
    }
  }
}

@Test func mapsNativeModelCapabilitiesWithoutInventingCapabilities() {
  let capabilities = AppleLocalAIModelCapabilities(
    LanguageModelCapabilities([.vision, .toolCalling])
  )

  #expect(capabilities.supportsVision)
  #expect(capabilities.supportsToolCalling)
  #expect(!capabilities.supportsGuidedGeneration)
  #expect(!capabilities.supportsReasoning)
}
