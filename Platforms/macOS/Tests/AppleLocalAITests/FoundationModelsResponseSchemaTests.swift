#if os(macOS)

  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels
  import Testing

  @Suite("Foundation Models response schema contract")
  struct FoundationModelsResponseSchemaTests {
    @Test func typedAndDynamicSchemasShareTheSameContract() throws {
      let typed = try JSONEncoder().encode(FoundationModelsResponseSchema.typed())
      let dynamic = try JSONEncoder().encode(FoundationModelsResponseSchema.dynamic())
      let typedJSON = String(decoding: typed, as: UTF8.self)
      let dynamicJSON = String(decoding: dynamic, as: UTF8.self)

      for key in [
        FoundationModelsResponseSchema.summaryKey,
        FoundationModelsResponseSchema.keyPointsKey,
        FoundationModelsResponseSchema.nextActionsKey,
      ] {
        #expect(typedJSON.contains("\"\(key)\""))
        #expect(dynamicJSON.contains("\"\(key)\""))
      }
      #expect(FoundationModelsResponseSchema.maximumListCount == 5)
    }

    @Test func generableProjectionUsesTheSameSchemaOwner() throws {
      let schema = try JSONEncoder().encode(FoundationModelsStructuredResponse.generationSchema)
      let json = String(decoding: schema, as: UTF8.self)
      #expect(json.contains("\"summary\""))
      #expect(json.contains("\"keyPoints\""))
      #expect(json.contains("\"nextActions\""))
    }
  }

#endif

#if os(macOS)
  @Test func rejectsMalformedAndSemanticallyEmptyStructuredResponses() throws {
    let missingArray = GeneratedContent(properties: ["summary": "hello"])
    #expect(throws: (any Error).self) {
      try FoundationModelsResponseSchema.decode(missingArray)
    }
    let empty = FoundationModelsStructuredResponse(summary: " \n", keyPoints: [], nextActions: [])
    #expect(throws: (any Error).self) {
      try FoundationModelsResponseSchema.decode(empty.generatedContent)
    }
    let oversized = FoundationModelsStructuredResponse(
      summary: "hello", keyPoints: Array(repeating: "point", count: 6), nextActions: [])
    #expect(throws: (any Error).self) {
      try FoundationModelsResponseSchema.decode(oversized.generatedContent)
    }

    let emptyListValue = FoundationModelsStructuredResponse(
      summary: "hello", keyPoints: ["  "], nextActions: [])
    #expect(throws: FoundationModelsResponseSchema.ValidationError.invalidContent) {
      try FoundationModelsResponseSchema.decode(emptyListValue.generatedContent)
    }
  }

  @Test func decodingNormalizesAcceptedTextValues() throws {
    let value = FoundationModelsStructuredResponse(
      summary: "  hello  ", keyPoints: ["  one  "], nextActions: [])
    let decoded = try FoundationModelsResponseSchema.decode(value.generatedContent)
    #expect(decoded.summary == "hello")
    #expect(decoded.keyPoints == ["one"])
  }
#endif
