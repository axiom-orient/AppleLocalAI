import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAILocalModels

@Generable
private struct LiteRTToolArguments {
  let value: String
}

@Test func rejectsUnmappedReasoningBeforeLoadingANativeEngine() {
  for level in [ContextOptions.ReasoningLevel.light, .moderate, .deep, .custom("extended")] {
    #expect(throws: LanguageModelError.self) {
      try LiteRTLMExecutor.validateContextOptions(.init(reasoningLevel: level))
    }
  }
}

@Test func contextValidationPreservesExistingSchemaPromptOptions() throws {
  for includeSchema in [true, false] {
    try LiteRTLMExecutor.validateContextOptions(.init(includeSchemaInPrompt: includeSchema))
  }
  try LiteRTLMExecutor.validateContextOptions(.init())
}

@Test func preflightRejectsMalformedTranscriptBeforeEngineAdmission() {
  let request = LanguageModelExecutorGenerationRequest(
    id: UUID(),
    transcript: Transcript(entries: [
      .response(.init(segments: [.text(.init(content: "already answered"))]))
    ]),
    enabledTools: [],
    schema: nil,
    generationOptions: .init(),
    contextOptions: .init(),
    metadata: [:])

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTLMExecutor.prepareGeneration(for: request)
  }
}

@Test func rejectsTranscriptEntryCountBeforeMaterializingHistory() {
  let transcript = Transcript(
    entries: Array(
      repeating: .reasoning(.init(segments: [])),
      count: LiteRTTranscriptPlanner.maximumTranscriptEntries + 1))

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  }
}

@Test func rejectsTranscriptInputBytesBeforeEngineAdmission() {
  let transcript = Transcript(entries: [
    .prompt(
      .init(segments: [
        .text(
          .init(
            content: String(
              repeating: "x", count: LiteRTTranscriptPlanner.maximumPromptBytes + 1)))
      ]))
  ])

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  }
}

@Test func acceptsExactTranscriptInputByteLimit() throws {
  let transcript = Transcript(entries: [
    .prompt(
      .init(segments: [
        .text(
          .init(
            content: String(repeating: "x", count: LiteRTTranscriptPlanner.maximumPromptBytes)))
      ]))
  ])

  let plan = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  #expect(plan.prompt.toString.utf8.count == LiteRTTranscriptPlanner.maximumPromptBytes)
}

@Test func rejectsTooManyToolDefinitionsBeforeBuildingInstructions() {
  let tools = (0...LiteRTTranscriptPlanner.maximumToolDefinitions).map { index in
    Transcript.ToolDefinition(
      name: "tool-\(index)", description: "A tool",
      parameters: LiteRTToolArguments.generationSchema)
  }
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Continue"))]))
  ])

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: tools)
  }
}

@Test func rejectsOversizedToolInstructionsBeforeEngineAdmission() {
  let tools = [
    Transcript.ToolDefinition(
      name: "lookup",
      description: String(repeating: "x", count: LiteRTTranscriptPlanner.maximumPromptBytes),
      parameters: LiteRTToolArguments.generationSchema)
  ]
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Continue"))]))
  ])

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: tools)
  }
}

@Test func textLiteRTModelsAdvertiseGuidedGeneration() {
  let metadata = LiteRTModelCapabilities(
    supportsText: true,
    supportsVision: false,
    supportsAudio: false,
    supportsVideo: false,
    supportsThinking: false,
    supportsFunctionCalling: false,
    maximumVisionTokenBudget: nil)

  let capabilities = metadata.foundationModelCapabilities(visionEnabled: false)

  #expect(capabilities.contains(.guidedGeneration))
  #expect(!capabilities.contains(.toolCalling))
}

@Test func toolCallingModeDoesNotDowngradeRequiredRequestsToText() throws {
  #expect(throws: LiteRTFMError.self) {
    try LiteRTLMExecutor.validateToolDefinitions(.required, count: 0)
  }
  #expect(throws: LiteRTFMError.self) {
    try LiteRTLMExecutor.validateSchemaAndToolCombination(
      hasSchema: false, .allowed,
      toolCount: LiteRTTranscriptPlanner.maximumToolDefinitions + 1)
  }
  #expect(throws: LiteRTFMError.self) {
    try LiteRTLMExecutor.validateToolCallResult(.required, count: 1, emittedToolCall: false)
  }
  try LiteRTLMExecutor.validateToolCallResult(.required, count: 1, emittedToolCall: true)
  try LiteRTLMExecutor.validateToolCallResult(.allowed, count: 1, emittedToolCall: false)
}

@Test func guidedOutputDoesNotDowngradeWhenToolsAreEnabled() throws {
  #expect(throws: LiteRTFMError.self) {
    try LiteRTLMExecutor.validateSchemaAndToolCombination(
      hasSchema: true, .allowed, toolCount: 1)
  }
  try LiteRTLMExecutor.validateSchemaAndToolCombination(
    hasSchema: true, .disallowed, toolCount: 1)
  try LiteRTLMExecutor.validateSchemaAndToolCombination(
    hasSchema: true, .allowed, toolCount: 0)
  try LiteRTLMExecutor.validateSchemaAndToolCombination(
    hasSchema: false, .allowed, toolCount: 1)
}

@Test func separatesCurrentPromptFromOrderedHistory() throws {
  let transcript = Transcript(entries: [
    .instructions(.init(segments: [.text(.init(content: "Be concise."))], toolDefinitions: [])),
    .prompt(.init(segments: [.text(.init(content: "Earlier question"))])),
    .response(.init(segments: [.text(.init(content: "Earlier answer"))])),
    .prompt(.init(segments: [.text(.init(content: "Current question"))])),
  ])
  let plan = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  #expect(plan.systemMessage?.toString == "Be concise.")
  #expect(plan.history.map(\.toString) == ["Earlier question", "Earlier answer"])
  #expect(plan.history.map(\.role.rawValue) == ["user", "assistant"])
  #expect(plan.prompt.toString == "Current question")
}

@Test func rejectsInstructionsInsertedAfterConversationHistory() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Earlier question"))])),
    .instructions(
      .init(segments: [.text(.init(content: "Late policy"))], toolDefinitions: [])),
    .prompt(.init(segments: [.text(.init(content: "Current question"))])),
  ])

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  }
}

@Test func rejectsTranscriptWithCompletedResponseAfterCurrentPrompt() {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Current question"))])),
    .response(.init(segments: [.text(.init(content: "Already answered"))])),
  ])

  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  }
}

@Test func allowsReasoningMetadataAfterCurrentPrompt() throws {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Current question"))])),
    .reasoning(.init(segments: [])),
  ])

  let plan = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  #expect(plan.prompt.toString == "Current question")
}

@Test func rejectsMissingPromptAndUnsupportedStructuredInput() throws {
  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: Transcript(entries: []), schemaJSON: nil, tools: [])
  }
  let structured = Transcript(entries: [
    .prompt(
      .init(segments: [
        .structure(.init(schemaName: "Value", content: try GeneratedContent(json: "{\"value\":1}")))
      ]))
  ])
  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: structured, schemaJSON: nil, tools: [])
  }
}

@Test func replaysGeneratedStructuredResponsesAsJSONHistory() throws {
  let generated = try GeneratedContent(json: #"{"value":"Earlier guided answer"}"#)
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Generate an answer"))])),
    .response(
      .init(segments: [
        .structure(.init(schemaName: "Answer", content: generated))
      ])),
    .prompt(.init(segments: [.text(.init(content: "Explain that answer"))])),
  ])
  let plan = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  #expect(plan.history.map(\.role.rawValue) == ["user", "assistant"])
  #expect(plan.history.last?.toString == generated.jsonString)
  #expect(plan.prompt.toString == "Explain that answer")
}

@Test func rejectsEmptyHistoricalToolGroups() {
  let transcript = Transcript(entries: [
    .toolCalls(.init([Transcript.ToolCall]())),
    .prompt(.init(segments: [.text(.init(content: "Continue"))])),
  ])
  #expect(throws: LiteRTFMError.self) {
    _ = try LiteRTTranscriptPlanner.make(from: transcript, schemaJSON: nil, tools: [])
  }
}

@Test func onlyRegisteredCompleteToolEnvelopesAuthorizeCalls() throws {
  let allowed: Set<String> = ["lookup"]
  let valid = try #require(
    try LiteRTToolCallEnvelope.parse(
      #"{"tool_call":{"name":"lookup","arguments":{"key":"value"}}}"#,
      allowedNames: allowed))
  #expect(valid.name == "lookup")
  #expect(valid.arguments == #"{"key":"value"}"#)
  #expect(try LiteRTToolCallEnvelope.parse("Ordinary response", allowedNames: allowed) == nil)

  for invalid in [
    #"{"tool_call":{"name":"unknown","arguments":{}}}"#,
    #"{"tool_call":{"name":"lookup","arguments":[]}}"#,
    #"{"tool_call":{"name":"lookup","arguments":{}},"extra":true}"#,
    #"Here is the call: {"tool_call":{"name":"lookup","arguments":{}}}"#,
    #"{"tool_call":"#,
  ] {
    #expect(throws: LiteRTToolCallEnvelope.EnvelopeError.self) {
      _ = try LiteRTToolCallEnvelope.parse(invalid, allowedNames: allowed)
    }
  }
}
