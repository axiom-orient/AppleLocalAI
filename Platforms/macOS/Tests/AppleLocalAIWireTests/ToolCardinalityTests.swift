import Foundation
import Testing

@testable import AppleLocalAIWire

@Suite("Shared tool-call cardinality")
struct ToolCardinalityTests {
  @Test(arguments: WireAPI.allCases)
  func serialRequestsAdmitAtMostOneCall(_ api: WireAPI) throws {
    let request = try makeRequest(api, choice: .auto, serial: true)
    #expect(request.serialTools)
    try request.validateToolCallCardinality([])
    try request.validateToolCallCardinality(calls(1))
    #expect(throws: parallelError) { try request.validateToolCallCardinality(calls(2)) }
  }

  @Test(arguments: WireAPI.allCases)
  func requiredSerialRequestsAdmitExactlyOneCall(_ api: WireAPI) throws {
    for choice in [WireToolChoice.required, .named("read")] {
      let request = try makeRequest(api, choice: choice, serial: true)
      #expect(request.toolChoice == choice)
      #expect(throws: missingError) { try request.validateToolCallCardinality([]) }
      try request.validateToolCallCardinality(calls(1))
      #expect(throws: parallelError) { try request.validateToolCallCardinality(calls(2)) }
    }
  }

  @Test(arguments: WireAPI.allCases)
  func parallelPermissionDoesNotChangeRequiredToolPresence(_ api: WireAPI) throws {
    let automatic = try makeRequest(api, choice: .auto, serial: false)
    #expect(!automatic.serialTools)
    try automatic.validateToolCallCardinality([])
    try automatic.validateToolCallCardinality(calls(2))
    let required = try makeRequest(api, choice: .required, serial: false)
    #expect(throws: missingError) { try required.validateToolCallCardinality([]) }
    try required.validateToolCallCardinality(calls(2))
  }

  @Test(arguments: WireAPI.allCases)
  func missingSerialFlagDoesNotAddAConstraint(_ api: WireAPI) throws {
    let request = try makeRequest(api, choice: .auto, serial: nil)
    #expect(!request.serialTools)
    try request.validateToolCallCardinality(calls(2))
  }

  @Test func messagesFlagIsStrictAndNested() throws {
    for invalid in [JSONValue.string("true"), .number(1), .object([:]), .array([])] {
      var body = payload(.messages, choice: .auto, serial: nil)
      body["tool_choice"] = .object(["type": .string("auto"), "disable_parallel_tool_use": invalid])
      #expect(throws: WireError.invalid("disable_parallel_tool_use must be boolean")) {
        try InferenceRequest.decode(api: .messages, data: JSONValue.object(body).encoded())
      }
    }
    var body = payload(.messages, choice: .auto, serial: nil)
    body["disable_parallel_tool_use"] = .bool(true)
    #expect(throws: WireError.self) {
      try InferenceRequest.decode(api: .messages, data: JSONValue.object(body).encoded())
    }
  }

  @Test func countValidationNeverMutatesOrDropsClientCalls() throws {
    let request = try makeRequest(.messages, choice: .auto, serial: true)
    let original = calls(2)
    #expect(throws: parallelError) { try request.validateToolCallCardinality(original) }
    #expect(original.map(\.id) == ["call_0", "call_1"])
    #expect(original.allSatisfy { $0.name == "read" && $0.arguments == .object([:]) })
  }

  private var parallelError: WireError {
    .unsupported(
      "Native model generated parallel calls despite a serial-only request; no tool was executed")
  }
  private var missingError: WireError {
    WireError(
      status: 502, code: "required_tool_missing",
      message: "The selected model returned no call for a required tool request")
  }
  private func calls(_ count: Int) -> [WireToolCall] {
    (0..<count).map { .init(id: "call_\($0)", name: "read", arguments: .object([:])) }
  }
  private func makeRequest(_ api: WireAPI, choice: WireToolChoice, serial: Bool?) throws
    -> InferenceRequest
  {
    try InferenceRequest.decode(
      api: api, data: JSONValue.object(payload(api, choice: choice, serial: serial)).encoded())
  }
  private func payload(_ api: WireAPI, choice: WireToolChoice, serial: Bool?) -> [String: JSONValue]
  {
    let schema = JSONValue.object([
      "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
    ])
    let message = JSONValue.object(["role": .string("user"), "content": .string("Read")])
    var body: [String: JSONValue] = ["model": .string("local")]
    switch api {
    case .chat, .responses:
      if api == .chat {
        body["messages"] = .array([message])
        body["tools"] = .array([
          .object([
            "type": .string("function"),
            "function": .object(["name": .string("read"), "parameters": schema]),
          ])
        ])
      } else {
        body["input"] = .string("Read")
        body["tools"] = .array([
          .object(["type": .string("function"), "name": .string("read"), "parameters": schema])
        ])
      }
      switch choice {
      case .auto: body["tool_choice"] = .string("auto")
      case .none: body["tool_choice"] = .string("none")
      case .required: body["tool_choice"] = .string("required")
      case .named(let name):
        body["tool_choice"] =
          api == .chat
          ? .object(["type": .string("function"), "function": .object(["name": .string(name)])])
          : .object(["type": .string("function"), "name": .string(name)])
      }
      if let serial { body["parallel_tool_calls"] = .bool(!serial) }
    case .messages:
      body["messages"] = .array([message])
      body["max_tokens"] = .number(20)
      body["tools"] = .array([.object(["name": .string("read"), "input_schema": schema])])
      var toolChoice: [String: JSONValue]
      switch choice {
      case .auto: toolChoice = ["type": .string("auto")]
      case .none: toolChoice = ["type": .string("none")]
      case .required: toolChoice = ["type": .string("any")]
      case .named(let name): toolChoice = ["type": .string("tool"), "name": .string(name)]
      }
      if let serial { toolChoice["disable_parallel_tool_use"] = .bool(serial) }
      body["tool_choice"] = .object(toolChoice)
    }
    return body
  }
}
