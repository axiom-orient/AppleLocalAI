import Foundation
import Testing

@testable import AppleLocalAIWire

private func decode(_ api: WireAPI, _ text: String) throws -> InferenceRequest {
  try InferenceRequest.decode(api: api, data: Data(text.utf8))
}

@Suite struct RequestTests {
  @Test func endpointPathIgnoresQueryParameters() throws {
    #expect(try WireAPI(path: "/v1/messages?beta=true") == .messages)
    #expect(try WireAPI(path: "/v1/responses?trace=1") == .responses)
    #expect(try WireAPI(path: "/v1/chat/completions?stream=true") == .chat)
  }

  @Test func chatInstructionsAndSampling() throws {
    let r = try decode(
      .chat,
      #"{"model":"local","messages":[{"role":"system","content":"Policy"},{"role":"developer","content":"Format"},{"role":"user","content":"안녕"}],"temperature":0.3,"top_p":0.9,"seed":42,"max_completion_tokens":32,"stream":true}"#
    )
    #expect(r.instructions == ["Policy", "Format"])
    #expect(r.entries == [.user("안녕")])
    #expect(r.seed == 42)
    #expect(r.maximumTokens == 32)
    #expect(r.stream)
  }

  @Test func temperatureBoundaryMatchesNativeFoundationModelsContract() throws {
    let chat = try decode(
      .chat,
      #"{"model":"x","messages":[{"role":"user","content":"x"}],"temperature":1}"#)
    #expect(chat.temperature == 1)

    let responses = try decode(.responses, #"{"model":"x","input":"x","temperature":1}"#)
    #expect(responses.temperature == 1)

    let messages = try decode(
      .messages,
      #"{"model":"x","max_tokens":8,"messages":[{"role":"user","content":"x"}],"temperature":1}"#)
    #expect(messages.temperature == 1)

    for api in WireAPI.allCases {
      let json: String
      switch api {
      case .chat:
        json = #"{"model":"x","messages":[{"role":"user","content":"x"}],"temperature":1.000001}"#
      case .responses:
        json = #"{"model":"x","input":"x","temperature":1.000001}"#
      case .messages:
        json = #"""
          {"model":"x","max_tokens":8,
           "messages":[{"role":"user","content":"x"}],"temperature":1.000001}
          """#
      }
      #expect(throws: (any Error).self) { try decode(api, json) }
    }
  }

  @Test(arguments: WireAPI.allCases)
  func topPBoundaryMatchesNativeFoundationModelsContract(_ api: WireAPI) throws {
    let accepted: String
    let rejected: String
    switch api {
    case .chat:
      accepted = #"{"model":"x","messages":[{"role":"user","content":"x"}],"top_p":0.01}"#
      rejected = #"{"model":"x","messages":[{"role":"user","content":"x"}],"top_p":0.009}"#
    case .responses:
      accepted = #"{"model":"x","input":"x","top_p":0.01}"#
      rejected = #"{"model":"x","input":"x","top_p":0.009}"#
    case .messages:
      accepted =
        #"{"model":"x","max_tokens":8,"messages":[{"role":"user","content":"x"}],"top_p":0.01}"#
      rejected =
        #"{"model":"x","max_tokens":8,"messages":[{"role":"user","content":"x"}],"top_p":0.009}"#
    }

    #expect(try decode(api, accepted).topP == 0.01)
    #expect(throws: (any Error).self) { try decode(api, rejected) }
  }

  @Test func toolIdentityAndLargeIntegerSurviveChat() throws {
    let r = try decode(
      .chat,
      #"{"model":"local","messages":[{"role":"user","content":"lookup"},{"role":"assistant","content":null,"tool_calls":[{"id":"c_1","type":"function","function":{"name":"lookup","arguments":"{\"id\":9223372036854775807}"}}]},{"role":"tool","tool_call_id":"c_1","name":"lookup","content":"done"}]}"#
    )
    guard case .toolCall(let call) = r.entries[1] else {
      Issue.record("Missing tool call")
      return
    }
    #expect(call.id == "c_1")
    #expect(call.name == "lookup")
    #expect(try call.arguments.jsonString() == #"{"id":9223372036854775807}"#)
    #expect(r.entries.last == .toolResult(id: "c_1", name: "lookup", text: "done"))
  }
  @Test func responsesAndMessagesProduceSameToolHistory() throws {
    let a = try decode(
      .responses,
      #"{"model":"local","input":[{"role":"user","content":"lookup"},{"type":"function_call","call_id":"x","name":"read","arguments":"{\"p\":\"a\"}"},{"type":"function_call_output","call_id":"x","output":"ok"}],"store":false}"#
    )
    let b = try decode(
      .messages,
      #"{"model":"local","max_tokens":32,"messages":[{"role":"user","content":"lookup"},{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"read","input":{"p":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}]}"#
    )
    #expect(a.entries == b.entries)
  }
  @Test func textBlocksDoNotInventTurns() throws {
    let r = try decode(
      .messages,
      #"{"model":"local","max_tokens":20,"messages":[{"role":"user","content":[{"type":"text","text":"하나"},{"type":"text","text":"둘"}]}]}"#
    )
    #expect(r.entries == [.user("하나둘")])
  }

  @Test func manyAdjacentTextBlocksPreserveOneMergedTurn() throws {
    let blocks: JSONValue = .array(
      (0..<2_048).map { _ -> JSONValue in
        .object(["type": .string("text"), "text": .string("x")])
      })
    let body = try JSONValue.object([
      "model": .string("local"),
      "max_tokens": .number(20),
      "messages": .array([
        .object(["role": .string("user"), "content": blocks])
      ]),
    ]).encoded()

    let request = try InferenceRequest.decode(api: .messages, data: body)
    #expect(
      request.entries == [WireEntry.user(String(repeating: "x", count: 2_048))]
    )
  }

  @Test func failedToolResultRemainsFailureData() throws {
    let r = try decode(
      .messages,
      #"{"model":"local","max_tokens":32,"messages":[{"role":"user","content":"read"},{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"read","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"denied","is_error":true}]}]}"#
    )
    #expect(
      r.entries.last
        == .toolResult(id: "x", name: "read", text: #"{"content":"denied","is_error":true}"#))
  }
  @Test func schemaRequiresNativeGuidedGeneration() throws {
    let r = try decode(
      .responses,
      #"{"model":"local","input":"a","text":{"format":{"type":"json_schema","name":"result","strict":true,"schema":{"type":"object","properties":{}}}}}"#
    )
    #expect(r.requirements.contains(.guidedGeneration))
  }
  @Test func namedFunctionChoiceAndSerialConstraint() throws {
    let r = try decode(
      .responses,
      #"{"model":"local","input":"a","tools":[{"type":"function","name":"read","parameters":{"type":"object","properties":{}}}],"tool_choice":{"type":"function","name":"read"},"parallel_tool_calls":false}"#
    )
    #expect(r.toolChoice == .named("read"))
    #expect(r.serialTools)
    #expect(r.requirements.contains(.toolCalling))
  }
  @Test(arguments: [
    #"{"model":"x","messages":[{"role":"user","content":"x","tool_calls":[] }]}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"},{"role":"system","content":"late"},{"role":"user","content":"y"}]}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"},{"role":"tool","tool_call_id":"orphan","content":"ok"}]}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"n":2}"#,
    #"{"model":"x","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"http://example.com"}}]}]}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"max_tokens":0}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"temperature":-1}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"temperature":1.000001}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"top_p":0}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"stream":"true"}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"seed":-1}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"tool_choice":"required"}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"t","parameters":{},"strict":"yes"}}]}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"unknown":true}"#,
    #"{"model":"x","messages":[{"role":"user","content":"x"}],"stop":["END"]}"#,
  ]) func malformedOrUnsupportedChatFails(_ json: String) {
    #expect(throws: (any Error).self) { try decode(.chat, json) }
  }
  @Test(arguments: [
    #"{"model":"x","input":"a","store":true}"#,
    #"{"model":"x","input":"a","previous_response_id":"r"}"#,
    #"{"model":"x","input":"a","include":["unknown_projection"]}"#,
    #"{"model":"x","input":"a","background":true}"#,
    #"{"model":"x","input":"a","reasoning":{"effort":"high","summary":"auto"}}"#,
    #"{"model":"x","input":"a","tools":[{"type":"custom","name":"apply_patch"}]}"#,
    #"{"model":"x","input":"a","stream":true,"text":{"format":{"type":"json_schema","schema":{}}}}"#,
  ]) func unsupportedResponsesFails(_ json: String) {
    #expect(throws: (any Error).self) { try decode(.responses, json) }
  }
  @Test func optionalReasoningProjectionDoesNotRequireFabricatedReasoning() throws {
    let request = try decode(
      .responses,
      #"{"model":"x","input":"hello","include":["reasoning.encrypted_content"],"reasoning":{"effort":"none","summary":"none"}}"#
    )
    #expect(request.entries == [.user("hello")])
    #expect(request.reasoning == "none")
  }

  @Test func openToolCallAndDuplicateResultsFail() {
    let prefix =
      #"{"model":"x","messages":[{"role":"user","content":"x"},{"role":"assistant","tool_calls":[{"id":"x","type":"function","function":{"name":"read","arguments":"{}"}}]}"#
    #expect(throws: (any Error).self) { try decode(.chat, prefix + "]}") }
    let result = #",{"role":"tool","tool_call_id":"x","content":"ok"}"#
    #expect(throws: (any Error).self) { try decode(.chat, prefix + result + result + "]}") }
  }
  @Test func requestSizeIsBounded() {
    #expect(throws: (any Error).self) {
      try InferenceRequest.decode(
        api: .responses,
        data: Data(repeating: 32, count: ProviderConfiguration.maximumBodyBytes + 1))
    }
  }
  @Test func unsupportedThinkingIsRejected() {
    #expect(throws: (any Error).self) {
      try decode(
        .messages,
        #"{"model":"x","max_tokens":10,"messages":[{"role":"user","content":"hi"}],"thinking":{"type":"adaptive"}}"#
      )
    }
  }

  @Test(arguments: WireAPI.allCases) func emptyUserInputIsRejected(_ api: WireAPI) {
    let body: String
    switch api {
    case .chat:
      body = #"{"model":"x","messages":[{"role":"user","content":"  "}]}"#
    case .responses:
      body = #"{"model":"x","input":"\n\t"}"#
    case .messages:
      body = #"{"model":"x","max_tokens":8,"messages":[{"role":"user","content":""}]}"#
    }
    #expect(throws: (any Error).self) { try decode(api, body) }
  }
}

@Suite struct RequestBoundaryRegressionTests {
  @Test(arguments: WireAPI.allCases)
  func nullSamplingFieldsAreTreatedAsOmitted(_ api: WireAPI) throws {
    let body: String
    switch api {
    case .chat:
      body = #"""
        {"model":"m","temperature":null,"top_p":null,"seed":null,
         "messages":[{"role":"user","content":"x"}]}
        """#
    case .responses:
      body = #"""
        {"model":"m","temperature":null,"top_p":null,"input":"x"}
        """#
    case .messages:
      body = #"""
        {"model":"m","max_tokens":8,"temperature":null,"top_p":null,
         "messages":[{"role":"user","content":"x"}]}
        """#
    }

    let request = try decode(api, body)
    #expect(request.temperature == nil)
    #expect(request.topP == nil)
    #expect(request.seed == nil)
  }

  @Test func nullChatTokenAliasDoesNotDiscardTheOtherLimit() throws {
    let maxTokensNull = try decode(
      .chat,
      #"{"model":"m","max_tokens":null,"max_completion_tokens":32,"messages":[{"role":"user","content":"x"}]}"#
    )
    #expect(maxTokensNull.maximumTokens == 32)

    let maxCompletionTokensNull = try decode(
      .chat,
      #"{"model":"m","max_tokens":24,"max_completion_tokens":null,"messages":[{"role":"user","content":"x"}]}"#
    )
    #expect(maxCompletionTokensNull.maximumTokens == 24)

    #expect(throws: (any Error).self) {
      try decode(
        .chat,
        #"{"model":"m","max_tokens":24,"max_completion_tokens":32,"messages":[{"role":"user","content":"x"}]}"#
      )
    }
  }

  @Test func historicalToolNameMustNotBeEmpty() {
    let body =
      #"{"model":"m","input":[{"role":"user","content":"read"},{"type":"function_call","call_id":"a","name":"","arguments":"{}"},{"type":"function_call_output","call_id":"a","output":"result"}]}"#
    #expect(throws: (any Error).self) {
      try InferenceRequest.decode(api: .responses, data: Data(body.utf8))
    }
  }

  @Test func messagesSerialChoiceUsesTheExistingSharedConstraint() throws {
    let body =
      #"{"model":"m","max_tokens":20,"messages":[{"role":"user","content":"read"}],"tool_choice":{"type":"auto","disable_parallel_tool_use":true}}"#
    let request = try decode(.messages, body)
    #expect(request.toolChoice == .auto)
    #expect(request.serialTools)
  }

  @Test func malformedParallelFlagIsNotIgnored() {
    let body =
      #"{"model":"m","max_tokens":20,"messages":[{"role":"user","content":"read"}],"tool_choice":{"type":"auto","disable_parallel_tool_use":"false"}}"#
    #expect(throws: (any Error).self) {
      try InferenceRequest.decode(api: .messages, data: Data(body.utf8))
    }
  }
}
