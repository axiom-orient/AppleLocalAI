import Foundation

package struct TokenUsage: Equatable, Sendable {
  package let input: Int
  package let cachedInput: Int
  package let output: Int
  package let reasoning: Int
  package init(input: Int, cachedInput: Int, output: Int, reasoning: Int) throws {
    guard input >= 0, output >= 0, cachedInput >= 0, reasoning >= 0,
      cachedInput <= input, reasoning <= output,
      !input.addingReportingOverflow(output).overflow
    else {
      throw WireError(
        status: 502, code: "invalid_usage", message: "Backend returned invalid token accounting")
    }
    self.input = input
    self.cachedInput = cachedInput
    self.output = output
    self.reasoning = reasoning
  }
  package var chat: JSONValue {
    .object([
      "prompt_tokens": exactTokenNumber(input),
      "completion_tokens": exactTokenNumber(output),
      "total_tokens": exactTokenNumber(input + output),
      "prompt_tokens_details": .object(["cached_tokens": exactTokenNumber(cachedInput)]),
      "completion_tokens_details": .object(["reasoning_tokens": exactTokenNumber(reasoning)]),
    ])
  }
  package var responses: JSONValue {
    .object([
      "input_tokens": exactTokenNumber(input),
      "output_tokens": exactTokenNumber(output),
      "total_tokens": exactTokenNumber(input + output),
      "input_tokens_details": .object(["cached_tokens": exactTokenNumber(cachedInput)]),
      "output_tokens_details": .object(["reasoning_tokens": exactTokenNumber(reasoning)]),
    ])
  }
  package var messages: JSONValue {
    .object([
      "input_tokens": exactTokenNumber(input - cachedInput),
      "cache_read_input_tokens": exactTokenNumber(cachedInput),
      "output_tokens": exactTokenNumber(output),
    ])
  }

  private func exactTokenNumber(_ value: Int) -> JSONValue {
    let asDouble = Double(value)
    guard Int(exactly: asDouble) == value else {
      return .signedInteger(Int64(value))
    }
    return .number(asDouble)
  }
}
package struct InferenceResult: Sendable {
  package let text: String
  package let calls: [WireToolCall]
  package let usage: TokenUsage?
  package let hitOutputLimit: Bool
  package init(
    text: String, calls: [WireToolCall], usage: TokenUsage?, hitOutputLimit: Bool = false
  ) {
    self.text = text
    self.calls = calls
    self.usage = usage
    self.hitOutputLimit = hitOutputLimit
  }
}

/// A wire response state, not a language-model session. It serializes real native
/// snapshots. Never manufactures token-by-token streaming from a finished answer.
package struct WireOutput {
  package let api: WireAPI
  package let model: String
  package let id: String
  package let created: Int
  private let textID: String
  private var sequence = 0
  private var started = false
  private var textStarted = false
  private var text = ""
  private var emittedText = ""
  private var terminal = false

  package init(
    api: WireAPI, model: String, id: String = UUID().uuidString,
    created: Int = Int(Date().timeIntervalSince1970)
  ) {
    self.api = api
    self.model = model
    self.id = "resp_" + id
    self.created = created
    self.textID = "msg_" + id
  }

  package static func validateTextOutput(_ text: String, message: String) throws {
    guard text.utf8.count <= ProviderConfiguration.maximumOutputBytes else {
      throw WireError(status: 502, code: "output_too_large", message: message)
    }
  }

  package static func addingToolArgumentBytes(_ total: Int, json: String) throws -> Int {
    let count = json.utf8.count
    let (next, overflow) = total.addingReportingOverflow(count)
    guard !overflow, next <= ProviderConfiguration.maximumToolArgumentsBytes else {
      throw WireError(
        status: 502, code: "tool_arguments_too_large",
        message: "Backend tool arguments exceed configured bound")
    }
    return next
  }

  package func response(_ result: InferenceResult) throws -> JSONValue {
    try validate(result)
    switch api {
    case .chat:
      var message: [String: JSONValue] = [
        "role": .string("assistant"), "content": .string(result.text),
      ]
      if !result.calls.isEmpty { message["tool_calls"] = .array(try result.calls.map(chatCall)) }
      var root: [String: JSONValue] = [
        "id": .string(id), "object": .string("chat.completion"),
        "created": .number(Double(created)), "model": .string(model),
        "choices": .array([
          .object([
            "index": .number(0), "message": .object(message),
            "finish_reason": .string(finish(result)),
          ])
        ]),
      ]
      if let usage = result.usage { root["usage"] = usage.chat }
      return .object(root)
    case .responses:
      var root: [String: JSONValue] = [
        "id": .string(id), "object": .string("response"), "created_at": .number(Double(created)),
        "model": .string(model),
        "status": .string(result.hitOutputLimit ? "incomplete" : "completed"), "error": .null,
        "incomplete_details": result.hitOutputLimit
          ? .object(["reason": .string("max_output_tokens")]) : .null,
        "output": .array(try responseItems(result)), "store": .bool(false),
      ]
      if let usage = result.usage { root["usage"] = usage.responses }
      return .object(root)
    case .messages:
      guard let usage = result.usage else {
        throw WireError.unavailable(
          "Backend does not provide trustworthy token usage required by Messages")
      }
      var blocks = [JSONValue]()
      if !result.text.isEmpty {
        blocks.append(.object(["type": .string("text"), "text": .string(result.text)]))
      }
      blocks += result.calls.map {
        .object([
          "type": .string("tool_use"), "id": .string($0.id), "name": .string($0.name),
          "input": $0.arguments,
        ])
      }
      return .object([
        "id": .string(textID), "type": .string("message"), "role": .string("assistant"),
        "model": .string(model),
        "content": .array(blocks),
        "stop_reason": .string(
          result.calls.isEmpty ? (result.hitOutputLimit ? "max_tokens" : "end_turn") : "tool_use"),
        "stop_sequence": .null, "usage": usage.messages,
      ])
    }
  }

  package mutating func snapshot(_ content: String, usage: TokenUsage?) throws -> [Data] {
    guard !terminal else { throw WireError.invalid("Stream is already terminal") }
    try Self.validateTextOutput(content, message: "Backend output exceeds configured bound")
    guard content.utf8.starts(with: text.utf8) else {
      throw WireError(
        status: 502, code: "non_monotonic_stream",
        message:
          "Native snapshot revised already observed content; append-only SSE cannot represent it")
    }
    text = content
    // Messages requires measured input usage. Until available, retain the native
    // snapshot without emitting a fabricated zero-token usage record.
    if api == .messages && !started && usage == nil { return [] }
    var frames = try start(usage: usage)
    guard !content.isEmpty else { return frames }
    if !textStarted {
      switch api {
      case .chat: break
      case .responses:
        frames += [
          try event(
            "response.output_item.added",
            ["output_index": .number(0), "item": textItem("", status: "in_progress")]),
          try event(
            "response.content_part.added",
            [
              "item_id": .string(textID), "output_index": .number(0), "content_index": .number(0),
              "part": textPart(""),
            ]),
        ]
      case .messages:
        frames += [
          try event(
            "content_block_start",
            [
              "index": .number(0),
              "content_block": .object(["type": .string("text"), "text": .string("")]),
            ])
        ]
      }
      textStarted = true
    }
    let delta = String(decoding: content.utf8.dropFirst(emittedText.utf8.count), as: UTF8.self)
    if !delta.isEmpty {
      switch api {
      case .chat: frames += [try data(chatChunk(delta: ["content": .string(delta)], finish: nil))]
      case .responses:
        frames += [
          try event(
            "response.output_text.delta",
            [
              "item_id": .string(textID), "output_index": .number(0), "content_index": .number(0),
              "delta": .string(delta), "logprobs": .array([]),
            ])
        ]
      case .messages:
        frames += [
          try event(
            "content_block_delta",
            [
              "index": .number(0),
              "delta": .object(["type": .string("text_delta"), "text": .string(delta)]),
            ])
        ]
      }
    }
    emittedText = content
    return frames
  }

  package mutating func complete(_ result: InferenceResult) throws -> [Data] {
    guard !terminal else { throw WireError.invalid("Stream is already terminal") }
    try validate(result)
    if api == .messages && result.usage == nil {
      throw WireError.unavailable("Missing trustworthy token usage for Messages")
    }
    var frames = try snapshot(result.text, usage: result.usage)
    frames += try start(usage: result.usage)
    if textStarted {
      switch api {
      case .chat: break
      case .responses:
        frames += [
          try event(
            "response.output_text.done",
            [
              "item_id": .string(textID), "output_index": .number(0), "content_index": .number(0),
              "text": .string(result.text), "logprobs": .array([]),
            ]),
          try event(
            "response.content_part.done",
            [
              "item_id": .string(textID), "output_index": .number(0), "content_index": .number(0),
              "part": textPart(result.text),
            ]),
          try event(
            "response.output_item.done",
            [
              "output_index": .number(0),
              "item": textItem(
                result.text, status: result.hitOutputLimit ? "incomplete" : "completed"),
            ]),
        ]
      case .messages: frames += [try event("content_block_stop", ["index": .number(0)])]
      }
    }
    for (offset, call) in result.calls.enumerated() {
      let index = offset + (textStarted ? 1 : 0)
      let arguments = try call.arguments.jsonString()
      switch api {
      case .chat:
        frames += [
          try data(
            chatChunk(
              delta: [
                "tool_calls": .array([
                  .object([
                    "index": .number(Double(offset)), "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                      "name": .string(call.name), "arguments": .string(arguments),
                    ]),
                  ])
                ])
              ], finish: nil))
        ]
      case .responses:
        let itemID = "fc_" + call.id
        frames += [
          try event(
            "response.output_item.added",
            [
              "output_index": .number(Double(index)),
              "item": responseCall(call, arguments: "", status: "in_progress"),
            ]),
          try event(
            "response.function_call_arguments.delta",
            [
              "item_id": .string(itemID), "output_index": .number(Double(index)),
              "delta": .string(arguments),
            ]),
          try event(
            "response.function_call_arguments.done",
            [
              "item_id": .string(itemID), "output_index": .number(Double(index)),
              "arguments": .string(arguments),
            ]),
          try event(
            "response.output_item.done",
            [
              "output_index": .number(Double(index)),
              "item": responseCall(call, arguments: arguments, status: "completed"),
            ]),
        ]
      case .messages:
        frames += [
          try event(
            "content_block_start",
            [
              "index": .number(Double(index)),
              "content_block": .object([
                "type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name),
                "input": .object([:]),
              ]),
            ]),
          try event(
            "content_block_delta",
            [
              "index": .number(Double(index)),
              "delta": .object([
                "type": .string("input_json_delta"), "partial_json": .string(arguments),
              ]),
            ]),
          try event("content_block_stop", ["index": .number(Double(index))]),
        ]
      }
    }
    switch api {
    case .chat:
      frames += [try data(chatChunk(delta: [:], finish: finish(result)))]
      if let usage = result.usage {
        frames += [
          try data(
            .object([
              "id": .string(id), "object": .string("chat.completion.chunk"),
              "created": .number(Double(created)), "model": .string(model), "choices": .array([]),
              "usage": usage.chat,
            ]))
        ]
      }
      frames += [Data("data: [DONE]\n\n".utf8)]
    case .responses:
      frames += [
        try event(
          result.hitOutputLimit ? "response.incomplete" : "response.completed",
          ["response": try response(result)])
      ]
    case .messages:
      let body = try response(result)
      guard let usage = result.usage else {
        throw WireError.unavailable(
          "Backend does not provide trustworthy token usage required by Messages")
      }
      frames += [
        try event(
          "message_delta",
          [
            "delta": .object(["stop_reason": body["stop_reason"] ?? .null, "stop_sequence": .null]),
            "usage": usage.messages,
          ]),
        try event("message_stop", [:]),
      ]
    }
    terminal = true
    return frames
  }

  private func validate(_ result: InferenceResult) throws {
    guard !result.text.isEmpty || !result.calls.isEmpty else {
      throw WireError(
        status: 502, code: "empty_response",
        message: "Native model returned neither text nor tool calls")
    }
    try Self.validateTextOutput(
      result.text, message: "Backend text output exceeds configured bound")
    guard result.calls.count <= ProviderConfiguration.maximumToolCount else {
      throw WireError(
        status: 502, code: "too_many_tool_calls", message: "Backend emitted too many tool calls")
    }
    var toolArgumentBytes = 0
    var callIDs = Set<String>()
    for call in result.calls {
      guard !call.id.isEmpty, !call.name.isEmpty, callIDs.insert(call.id).inserted,
        call.arguments.object != nil
      else {
        throw WireError(
          status: 502, code: "invalid_tool_call",
          message: "Tool calls require unique non-empty IDs, names, and object arguments")
      }
      toolArgumentBytes = try Self.addingToolArgumentBytes(
        toolArgumentBytes, json: call.arguments.jsonString())
    }
  }

  package mutating func failure(_ error: WireError) throws -> [Data] {
    guard !terminal else { return [] }
    terminal = true
    switch api {
    case .responses:
      return [
        try event(
          "response.failed",
          [
            "response": .object([
              "id": .string(id), "object": .string("response"), "status": .string("failed"),
              "output": .array([]),
              "error": .object(["code": .string(error.code), "message": .string(error.message)]),
            ])
          ])
      ]
    case .messages:
      return [
        try event(
          "error",
          [
            "error": .object([
              "type": .string(error.code), "message": .string(error.message),
            ])
          ])
      ]
    case .chat: return [try data(error.json)]
    }
  }

  private mutating func start(usage: TokenUsage?) throws -> [Data] {
    guard !started else { return [] }
    if api == .messages && usage == nil { return [] }
    started = true
    switch api {
    case .chat: return [try data(chatChunk(delta: ["role": .string("assistant")], finish: nil))]
    case .responses:
      let response: JSONValue = .object([
        "id": .string(id), "object": .string("response"), "created_at": .number(Double(created)),
        "model": .string(model), "status": .string("in_progress"), "output": .array([]),
      ])
      return [
        try event("response.created", ["response": response]),
        try event("response.in_progress", ["response": response]),
      ]
    case .messages:
      // Empty output at message_start is a protocol state, not an estimate of
      // the backend's final output. Final measured usage replaces it.
      guard let usage else { return [] }
      let initialUsage = try TokenUsage(
        input: usage.input, cachedInput: usage.cachedInput, output: 0, reasoning: 0)
      return [
        try event(
          "message_start",
          [
            "message": .object([
              "id": .string(textID), "type": .string("message"), "role": .string("assistant"),
              "model": .string(model), "content": .array([]), "stop_reason": .null,
              "stop_sequence": .null, "usage": initialUsage.messages,
            ])
          ])
      ]
    }
  }
  private func textPart(_ text: String) -> JSONValue {
    .object([
      "type": .string("output_text"), "text": .string(text), "annotations": .array([]),
      "logprobs": .array([]),
    ])
  }
  private func textItem(_ text: String, status: String) -> JSONValue {
    .object([
      "id": .string(textID), "type": .string("message"), "role": .string("assistant"),
      "status": .string(status), "content": text.isEmpty ? .array([]) : .array([textPart(text)]),
    ])
  }
  private func responseCall(_ call: WireToolCall, arguments: String, status: String) -> JSONValue {
    .object([
      "id": .string("fc_" + call.id), "type": .string("function_call"), "call_id": .string(call.id),
      "name": .string(call.name), "arguments": .string(arguments), "status": .string(status),
    ])
  }
  private func responseItems(_ result: InferenceResult) throws -> [JSONValue] {
    var items: [JSONValue] =
      result.text.isEmpty
      ? [] : [textItem(result.text, status: result.hitOutputLimit ? "incomplete" : "completed")]
    items += try result.calls.map {
      responseCall($0, arguments: try $0.arguments.jsonString(), status: "completed")
    }
    return items
  }
  private func chatCall(_ call: WireToolCall) throws -> JSONValue {
    .object([
      "id": .string(call.id), "type": .string("function"),
      "function": .object([
        "name": .string(call.name), "arguments": .string(try call.arguments.jsonString()),
      ]),
    ])
  }
  private func finish(_ result: InferenceResult) -> String {
    !result.calls.isEmpty ? "tool_calls" : (result.hitOutputLimit ? "length" : "stop")
  }
  private func chatChunk(delta: [String: JSONValue], finish: String?) -> JSONValue {
    .object([
      "id": .string(id), "object": .string("chat.completion.chunk"),
      "created": .number(Double(created)), "model": .string(model),
      "choices": .array([
        .object([
          "index": .number(0), "delta": .object(delta),
          "finish_reason": finish.map(JSONValue.string) ?? .null,
        ])
      ]),
    ])
  }
  private func data(_ value: JSONValue) throws -> Data {
    Data("data: \(try value.jsonString())\n\n".utf8)
  }
  private mutating func event(_ name: String, _ fields: [String: JSONValue]) throws -> Data {
    var payload = fields
    payload["type"] = .string(name)
    if api == .responses {
      payload["sequence_number"] = .number(Double(sequence))
      sequence += 1
    }
    return Data("event: \(name)\ndata: \(try JSONValue.object(payload).jsonString())\n\n".utf8)
  }
}
