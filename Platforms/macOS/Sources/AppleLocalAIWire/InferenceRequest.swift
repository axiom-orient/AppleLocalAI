import AppleLocalAIHost
import Foundation

package enum WireAPI: String, Sendable, CaseIterable {
  case chat, responses, messages
  package init(path: String) throws {
    let route =
      path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
      .map(String.init) ?? path
    switch route {
    case "/v1/chat/completions": self = .chat
    case "/v1/responses": self = .responses
    case "/v1/messages": self = .messages
    default: throw WireError(status: 404, code: "not_found", message: "Unknown inference endpoint")
    }
  }
}
package struct WireTool: Equatable, Sendable {
  package var name: String
  package var description: String
  package var schema: JSONValue
}
package struct WireToolCall: Equatable, Sendable {
  package var id: String
  package var name: String
  package var arguments: JSONValue

  package init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}
package enum WireEntry: Equatable, Sendable {
  case user(String)
  case assistant(String)
  case toolCall(WireToolCall)
  case toolResult(id: String, name: String, text: String)
}
package enum WireToolChoice: Equatable, Sendable {
  case none, auto, required
  case named(String)
}

/// Lossless, validated text/function subset of the three client protocols.
/// Unsupported semantics are rejected before a native model is loaded.
package struct InferenceRequest: Equatable, Sendable {
  package let api: WireAPI
  package var model: String
  package var instructions: [String]
  package var entries: [WireEntry]
  package var tools: [WireTool]
  package var toolChoice: WireToolChoice
  package var stream: Bool
  package var maximumTokens: Int?
  package var temperature: Double?
  package var topP: Double?
  package var seed: UInt64?
  package var reasoning: String?
  package var schema: JSONValue?

  package var requirements: Set<ModelRequirement> {
    var result = Set<ModelRequirement>()
    if !tools.isEmpty && toolChoice != .none { result.insert(.toolCalling) }
    if schema != nil { result.insert(.guidedGeneration) }
    if let reasoning, reasoning != "none" { result.insert(.reasoning) }
    return result
  }

  package static func decode(api: WireAPI, data: Data) throws -> Self {
    guard data.count <= ProviderConfiguration.maximumBodyBytes else {
      throw WireError(status: 413, code: "request_too_large", message: "Request body exceeds limit")
    }
    let root: JSONValue
    do { root = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
      throw WireError.invalid("Malformed JSON request")
    }
    let common: Set<String> = [
      "model", "stream", "tools", "tool_choice", "temperature", "top_p", "metadata",
    ]
    let allowed: Set<String>
    switch api {
    case .chat:
      allowed = common.union([
        "messages", "max_tokens", "max_completion_tokens", "seed", "n", "stop", "stream_options",
        "response_format", "parallel_tool_calls", "reasoning_effort", "user", "store",
      ])
    case .responses:
      allowed = common.union([
        "input", "instructions", "max_output_tokens", "reasoning", "text", "store",
        "previous_response_id", "include", "parallel_tool_calls", "truncation", "background",
        "prompt_cache_key", "safety_identifier",
      ])
    case .messages:
      allowed = common.union([
        "messages", "system", "max_tokens", "stop_sequences", "thinking", "output_config",
      ])
    }
    try root.allowingOnly(allowed)
    let model = try root.requiredString("model")
    guard !model.isEmpty else { throw WireError.invalid("model must not be empty") }
    let stream = try optionalBool(root, "stream") ?? false
    if let store = try optionalBool(root, "store"), store {
      throw WireError.unsupported(
        "Server-side response storage is disabled; send complete history with store:false")
    }
    if let previous = root["previous_response_id"], previous != .null {
      throw WireError.unsupported("previous_response_id is not supported; replay complete input")
    }
    if try optionalBool(root, "background") == true {
      throw WireError.unsupported("Background response jobs are not supported")
    }
    if let truncation = root["truncation"], truncation != .string("disabled") {
      throw WireError.unsupported(
        "Automatic truncation is disabled; choose an explicit profile historyWindow")
    }
    if let includes = root["include"] {
      guard let values = includes.array,
        values.allSatisfy({ $0 == .string("reasoning.encrypted_content") })
      else {
        throw WireError.unsupported("Unsupported include projection")
      }
      // include selects optional fields on output items; it does not require
      // producing a reasoning item. This provider returns text/function items
      // only, never invents encrypted reasoning, and rejects reasoning replay.
    }
    if let n = root["n"], n != .number(1) { throw WireError.unsupported("Only n:1 is supported") }
    for key in ["stop", "stop_sequences"] {
      if let value = root[key], value != .null, value != .array([]) {
        throw WireError.unsupported(
          "Custom stop sequences are not supported by the native session adapter")
      }
    }
    if let parallel = root["parallel_tool_calls"] {
      guard parallel.bool != nil else {
        throw WireError.invalid("parallel_tool_calls must be boolean")
      }
      // FM owns grouping. A false value is enforced by rejecting multi-call output,
      // not by executing or silently dropping any of the calls.
    }
    if let options = root["stream_options"] {
      try options.allowingOnly(["include_usage"])
      _ = try optionalBool(options, "include_usage")
    }
    var request = Self(
      api: api, model: model, instructions: [], entries: [], tools: [],
      toolChoice: .auto, stream: stream, maximumTokens: nil, temperature: nil,
      topP: nil, seed: nil, reasoning: nil, schema: nil)
    switch api {
    case .chat:
      guard let messages = root["messages"]?.array else {
        throw WireError.invalid("messages must be an array")
      }
      for message in messages { try request.appendChat(message) }
      let maxTokensField = root["max_tokens"]
      let maxCompletionTokensField = root["max_completion_tokens"]
      let hasMaxTokens = maxTokensField.map { $0 != .null } ?? false
      let hasMaxCompletionTokens = maxCompletionTokensField.map { $0 != .null } ?? false
      if hasMaxTokens && hasMaxCompletionTokens {
        throw WireError.invalid("Choose one token limit")
      }
      request.maximumTokens = try optionalPositiveInt(
        root, hasMaxCompletionTokens ? "max_completion_tokens" : "max_tokens")
      if let format = root["response_format"] {
        if format["type"] == .string("text") {
          try format.allowingOnly(["type"])
        } else if format["type"] == .string("json_schema") {
          try format.allowingOnly(["type", "json_schema"])
          guard let spec = format["json_schema"] else {
            throw WireError.invalid("Missing json_schema")
          }
          try spec.allowingOnly(["name", "description", "schema", "strict"])
          _ = try optionalBool(spec, "strict")
          request.schema = spec["schema"]
          guard request.schema != nil else { throw WireError.invalid("Missing output schema") }
        } else {
          throw WireError.unsupported("Use text or json_schema, not prompt-only JSON mode")
        }
      }
      request.reasoning = try optionalString(root, "reasoning_effort")
      if let value = root["seed"], value != .null {
        guard let n = value.integer, n >= 0 else {
          throw WireError.invalid("seed must be a nonnegative integer")
        }
        request.seed = UInt64(n)
      }
    case .responses:
      if let instructions = try optionalString(root, "instructions") {
        request.instructions.append(instructions)
      }
      if let input = root["input"]?.string {
        request.entries.append(.user(input))
      } else if let input = root["input"]?.array {
        for entry in input { try request.appendResponseInput(entry) }
      } else {
        throw WireError.invalid("input must be text or an array")
      }
      request.maximumTokens = try optionalPositiveInt(root, "max_output_tokens")
      if let reasoning = root["reasoning"] {
        try reasoning.allowingOnly(["effort", "summary"])
        if let summary = reasoning["summary"], summary != .null, summary != .string("none") {
          throw WireError.unsupported("Reasoning summaries are not exposed; omit reasoning.summary")
        }
        request.reasoning = try optionalString(reasoning, "effort")
      }
      if let text = root["text"] {
        try text.allowingOnly(["format"])
        if let format = text["format"] {
          try format.allowingOnly(["type", "name", "description", "schema", "strict"])
          switch format["type"]?.string {
          case "text": try format.allowingOnly(["type"])
          case "json_schema":
            _ = try optionalBool(format, "strict")
            request.schema = format["schema"]
            guard request.schema != nil else { throw WireError.invalid("Missing output schema") }
          default: throw WireError.unsupported("Unsupported output format")
          }
        }
      }
    case .messages:
      if let system = root["system"] {
        request.instructions.append(try textContent(system, allowedTypes: ["text"]))
      }
      guard let messages = root["messages"]?.array else {
        throw WireError.invalid("messages must be an array")
      }
      for message in messages { try request.appendAnthropic(message) }
      request.maximumTokens = try optionalPositiveInt(root, "max_tokens")
      guard request.maximumTokens != nil else {
        throw WireError.invalid("Messages requires max_tokens")
      }
      if let thinking = root["thinking"] {
        try thinking.allowingOnly(["type"])
        guard thinking["type"] == .string("disabled") else {
          throw WireError.unsupported(
            "Use the configured native reasoning profile; Anthropic thinking signatures/budgets are not interchangeable"
          )
        }
      }
      if let output = root["output_config"] {
        try output.allowingOnly(["effort"])
        request.reasoning = try optionalString(output, "effort")
      }
    }
    if let value = root["temperature"], value != .null {
      guard let n = value.number, GenerationPolicy.acceptsTemperature(n) else {
        throw WireError.invalid("temperature must be in 0...1")
      }
      request.temperature = n
    }
    if let value = root["top_p"], value != .null {
      guard let n = value.number, GenerationPolicy.acceptsProbabilityThreshold(n) else {
        throw WireError.invalid("top_p must be in [0.01,1]")
      }
      request.topP = n
    }
    if let reasoning = request.reasoning, !["none", "low", "medium", "high"].contains(reasoning) {
      throw WireError.unsupported("Native reasoning mapping supports none/low/medium/high only")
    }
    if let tools = root["tools"] {
      guard let list = tools.array, list.count <= ProviderConfiguration.maximumToolCount else {
        throw WireError.invalid("Invalid tools array or too many tools")
      }
      request.tools = try list.map { try decodeTool($0, api: api) }
      guard Set(request.tools.map(\.name)).count == request.tools.count else {
        throw WireError.invalid("Duplicate tool names")
      }
    }
    request.toolChoice = try decodeToolChoice(root["tool_choice"], api: api)
    if case .named(let name) = request.toolChoice,
      !request.tools.contains(where: { $0.name == name })
    {
      throw WireError.invalid("Named tool is not registered")
    }
    if request.toolChoice == .required && request.tools.isEmpty {
      throw WireError.invalid("Required tool choice needs tools")
    }
    if request.schema != nil && request.stream {
      throw WireError.unsupported(
        "Structured snapshots are not append-only JSON; use stream:false for schema output")
    }
    if let schema = request.schema, schema.object == nil {
      throw WireError.invalid("Output schema must be an object")
    }
    try request.validateHistory()
    // Retain this constraint explicitly in the request rather than hiding it.
    if api == .messages {
      request.serialTools =
        try optionalBool(root["tool_choice"] ?? .null, "disable_parallel_tool_use") ?? false
    } else {
      request.serialTools = root["parallel_tool_calls"] == .bool(false)
    }
    return request
  }

  package var serialTools = false

  /// Applies the caller's shared terminal tool-count contract. This does not
  /// execute, truncate or retry calls and does not change the native sampler.
  /// NativeRequestSchemas and the handoff adapter validate names/arguments.
  package func validateToolCallCardinality(_ calls: [WireToolCall]) throws {
    if serialTools && calls.count > 1 {
      throw WireError.unsupported(
        "Native model generated parallel calls despite a serial-only request; no tool was executed"
      )
    }
    if calls.isEmpty {
      switch toolChoice {
      case .required, .named:
        throw WireError(
          status: 502, code: "required_tool_missing",
          message: "The selected model returned no call for a required tool request")
      case .auto, .none: break
      }
    }
  }

  private mutating func appendChat(_ message: JSONValue) throws {
    try message.allowingOnly(["role", "content", "tool_calls", "tool_call_id", "name"])
    let role = try message.requiredString("role")
    if role != "assistant", let calls = message["tool_calls"], calls != .null {
      throw WireError.invalid("tool_calls belongs to assistant messages only")
    }
    if role != "tool", let id = message["tool_call_id"], id != .null {
      throw WireError.invalid("tool_call_id belongs to tool messages only")
    }
    if role == "tool", let name = message["name"], name != .null, name.string == nil {
      throw WireError.invalid("Tool message name must be text")
    }
    if let name = message["name"], role != "tool", name != .null {
      throw WireError.unsupported("Named chat participants are not supported")
    }
    switch role {
    case "system", "developer":
      guard entries.isEmpty else {
        throw WireError.unsupported(
          "Instruction changes embedded mid-history require an explicit new profile, not reordered messages"
        )
      }
      instructions.append(try Self.textContent(message["content"] ?? .null, allowedTypes: ["text"]))
    case "user":
      entries.append(
        .user(try Self.textContent(message["content"] ?? .null, allowedTypes: ["text"])))
    case "assistant":
      if let content = message["content"], content != .null {
        let text = try Self.textContent(content, allowedTypes: ["text"])
        if !text.isEmpty { entries.append(.assistant(text)) }
      }
      if let tools = message["tool_calls"] {
        guard let calls = tools.array else {
          throw WireError.invalid("tool_calls must be an array")
        }
        for call in calls {
          try call.allowingOnly(["id", "type", "function"])
          guard call["type"] == .string("function"), let function = call["function"] else {
            throw WireError.unsupported("Only function tools are supported")
          }
          try function.allowingOnly(["name", "arguments"])
          entries.append(
            .toolCall(
              .init(
                id: try call.requiredString("id"), name: try function.requiredString("name"),
                arguments: try Self.arguments(function["arguments"]))))
        }
      }
    case "tool":
      try appendResult(
        id: message.requiredString("tool_call_id"), name: message["name"]?.string,
        text: Self.textContent(message["content"] ?? .null, allowedTypes: ["text"]))
    default: throw WireError.unsupported("Unsupported role: \(role)")
    }
  }

  private mutating func appendResponseInput(_ entry: JSONValue) throws {
    let type = entry["type"]?.string ?? "message"
    switch type {
    case "message":
      try entry.allowingOnly(["type", "id", "role", "content", "status"])
      let role = try entry.requiredString("role")
      let content = try Self.textContent(
        entry["content"] ?? .null, allowedTypes: ["input_text", "output_text"])
      switch role {
      case "user": entries.append(.user(content))
      case "assistant": entries.append(.assistant(content))
      case "system", "developer":
        guard entries.isEmpty else {
          throw WireError.unsupported("Mid-history instructions cannot be reordered")
        }
        instructions.append(content)
      default: throw WireError.unsupported("Unsupported Responses role")
      }
    case "function_call":
      try entry.allowingOnly(["type", "id", "call_id", "name", "arguments", "status"])
      entries.append(
        .toolCall(
          .init(
            id: try entry.requiredString("call_id"), name: try entry.requiredString("name"),
            arguments: try Self.arguments(entry["arguments"]))))
    case "function_call_output":
      try entry.allowingOnly(["type", "id", "call_id", "output", "status"])
      try appendResult(
        id: entry.requiredString("call_id"), name: nil,
        text: Self.textContent(entry["output"] ?? .null, allowedTypes: ["input_text"]))
    default: throw WireError.unsupported("Unsupported Responses input type: \(type)")
    }
  }

  private mutating func appendAnthropic(_ message: JSONValue) throws {
    try message.allowingOnly(["role", "content"])
    let role = try message.requiredString("role")
    guard ["user", "assistant"].contains(role) else {
      throw WireError.invalid("Messages roles must be user/assistant")
    }
    guard let content = message["content"] else {
      throw WireError.invalid("Missing message content")
    }
    if let text = content.string {
      entries.append(role == "user" ? .user(text) : .assistant(text))
      return
    }
    guard let blocks = content.array else { throw WireError.invalid("Invalid message content") }
    var textRunParts = [String]()
    var hasTextRun = false
    func flushText() -> WireEntry? {
      guard hasTextRun else { return nil }
      let text = textRunParts.joined()
      textRunParts.removeAll(keepingCapacity: true)
      hasTextRun = false
      return role == "user" ? .user(text) : .assistant(text)
    }
    for block in blocks {
      let type = try block.requiredString("type")
      if type != "text", let text = flushText() { entries.append(text) }
      switch type {
      case "text":
        try block.allowingOnly(["type", "text", "cache_control"])
        let text = try block.requiredString("text")
        textRunParts.append(text)
        hasTextRun = true
      case "tool_use":
        try block.allowingOnly(["type", "id", "name", "input", "cache_control"])
        guard role == "assistant", let arguments = block["input"], arguments.object != nil else {
          throw WireError.invalid("tool_use must be assistant content with object input")
        }
        entries.append(
          .toolCall(
            .init(
              id: try block.requiredString("id"), name: try block.requiredString("name"),
              arguments: arguments)))
      case "tool_result":
        try block.allowingOnly(["type", "tool_use_id", "content", "is_error", "cache_control"])
        guard role == "user" else { throw WireError.invalid("tool_result must be user content") }
        if let error = block["is_error"], error.bool == nil {
          throw WireError.invalid("is_error must be boolean")
        }
        var text = try Self.textContent(block["content"] ?? .string(""), allowedTypes: ["text"])
        // The native ToolOutput has no is_error field. Preserve it in structured
        // output text instead of misrepresenting failed execution as success.
        if block["is_error"] == .bool(true) {
          text = try JSONValue.object(["is_error": .bool(true), "content": .string(text)])
            .jsonString()
        }
        try appendResult(id: block.requiredString("tool_use_id"), name: nil, text: text)
      default: throw WireError.unsupported("Unsupported Messages content type: \(type)")
      }
    }
    if let text = flushText() { entries.append(text) }
  }

  private mutating func appendResult(id: String, name: String?, text: String) throws {
    guard
      let call = entries.compactMap({ if case .toolCall(let c) = $0 { c } else { nil } }).last(
        where: { $0.id == id }),
      name == nil || name == call.name
    else { throw WireError.invalid("Tool output has no matching call/name: \(id)") }
    entries.append(.toolResult(id: id, name: call.name, text: text))
  }

  private mutating func validateHistory() throws {
    guard !entries.isEmpty, entries.count <= ProviderConfiguration.maximumHistoryEntries else {
      throw WireError.invalid("History must contain 1...4096 entries")
    }
    var pending = Set<String>()
    var seen = Set<String>()
    var hasUser = false
    for entry in entries {
      switch entry {
      case .user(let text):
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw WireError.invalid("User input must not be empty")
        }
        guard pending.isEmpty else {
          throw WireError.invalid("Missing tool output before the next user turn")
        }
        hasUser = true
      case .assistant:
        guard pending.isEmpty else {
          throw WireError.invalid("Assistant text before outstanding tool outputs")
        }
      case .toolCall(let call):
        guard hasUser, !call.id.isEmpty, !call.name.isEmpty,
          seen.insert(call.id).inserted, call.arguments.object != nil
        else { throw WireError.invalid("Invalid/duplicate tool call") }
        pending.insert(call.id)
      case .toolResult(let id, _, _):
        guard pending.remove(id) != nil else {
          throw WireError.invalid("Duplicate or orphaned tool result")
        }
      }
    }
    guard pending.isEmpty else {
      throw WireError.invalid("Every input tool call requires its corresponding result")
    }
    switch entries.last {
    case .user?, .toolResult?: break
    default: throw WireError.invalid("Request must end with user input or tool output")
    }
    guard hasUser else { throw WireError.invalid("History must contain a user turn") }
  }

  private static func arguments(_ value: JSONValue?) throws -> JSONValue {
    guard let string = value?.string,
      let result = try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)),
      result.object != nil
    else { throw WireError.invalid("Tool arguments must be a JSON object encoded as a string") }
    return result
  }
  private static func decodeTool(_ value: JSONValue, api: WireAPI) throws -> WireTool {
    let body: JSONValue
    switch api {
    case .chat:
      try value.allowingOnly(["type", "function"])
      guard value["type"] == .string("function"), let function = value["function"] else {
        throw WireError.unsupported("Only function tools are supported")
      }
      body = function
      try body.allowingOnly(["name", "description", "parameters", "strict"])
    case .responses:
      try value.allowingOnly(["type", "name", "description", "parameters", "strict"])
      guard value["type"] == .string("function") else {
        throw WireError.unsupported(
          "Only function tools are supported; custom/built-in tools require a separate adapter")
      }
      body = value
    case .messages:
      try value.allowingOnly(["name", "description", "input_schema", "cache_control"])
      body = value
    }
    _ = try optionalBool(body, "strict")
    let name = try body.requiredString("name")
    guard !name.isEmpty, name.utf8.count <= 128,
      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) })
    else { throw WireError.invalid("Invalid tool name") }
    guard let schema = body[api == .messages ? "input_schema" : "parameters"], schema.object != nil
    else { throw WireError.invalid("Tool parameters require a JSON schema object") }
    return WireTool(
      name: name, description: try optionalString(body, "description") ?? "", schema: schema)
  }
  private static func decodeToolChoice(_ value: JSONValue?, api: WireAPI) throws -> WireToolChoice {
    guard let value, value != .null else { return .auto }
    if let text = value.string {
      switch text {
      case "auto": return .auto
      case "none": return .none
      case "required": return .required
      default: throw WireError.unsupported("Unsupported tool_choice")
      }
    }
    if api == .messages {
      try value.allowingOnly(["type", "name", "disable_parallel_tool_use"])
      switch value["type"]?.string {
      case "auto": return .auto
      case "none": return .none
      case "any": return .required
      case "tool": return .named(try value.requiredString("name"))
      default: throw WireError.unsupported("Unsupported tool_choice")
      }
    }
    try value.allowingOnly(api == .chat ? ["type", "function"] : ["type", "name"])
    guard value["type"] == .string("function") else {
      throw WireError.unsupported("Unsupported tool_choice")
    }
    if api == .chat {
      guard let function = value["function"] else {
        throw WireError.invalid("Missing named function")
      }
      try function.allowingOnly(["name"])
      return .named(try function.requiredString("name"))
    }
    return .named(try value.requiredString("name"))
  }
  private static func textContent(_ value: JSONValue, allowedTypes: Set<String>) throws -> String {
    if let text = value.string { return text }
    guard let array = value.array else { throw WireError.invalid("Expected text content") }
    return try array.map { part in
      try part.allowingOnly(["type", "text", "annotations", "logprobs", "cache_control"])
      guard let type = part["type"]?.string, allowedTypes.contains(type) else {
        throw WireError.unsupported(
          "Only text content is supported on the HTTP boundary; use the native API for vision")
      }
      if let annotations = part["annotations"], annotations != .array([]) {
        throw WireError.unsupported(
          "Annotations cannot be represented in the native text transcript")
      }
      if let logprobs = part["logprobs"], logprobs != .null, logprobs != .array([]) {
        throw WireError.unsupported("Nonempty logprobs cannot be replayed in a native transcript")
      }
      return try part.requiredString("text")
    }.joined()
  }
  private static func optionalBool(_ value: JSONValue, _ key: String) throws -> Bool? {
    guard let field = value[key], field != .null else { return nil }
    guard let bool = field.bool else { throw WireError.invalid("\(key) must be boolean") }
    return bool
  }
  private static func optionalString(_ value: JSONValue, _ key: String) throws -> String? {
    guard let field = value[key], field != .null else { return nil }
    guard let string = field.string else { throw WireError.invalid("\(key) must be string") }
    return string
  }
  private static func optionalPositiveInt(_ value: JSONValue, _ key: String) throws -> Int? {
    guard let field = value[key], field != .null else { return nil }
    guard let int = field.integer, int > 0, int <= ProviderConfiguration.maximumResponseTokens
    else {
      throw WireError.invalid("\(key) must be an integer in 1...1048576")
    }
    return int
  }
}
