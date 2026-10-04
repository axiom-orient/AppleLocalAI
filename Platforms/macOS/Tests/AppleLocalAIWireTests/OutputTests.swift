import Foundation
import Testing

@testable import AppleLocalAIWire

private func events(_ frames: [Data]) throws -> [JSONValue] {
  try frames.flatMap { data in
    try String(decoding: data, as: UTF8.self).split(separator: "\n").filter {
      $0.hasPrefix("data: ") && $0 != "data: [DONE]"
    }.map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.dropFirst(6).utf8))
    }
  }
}
@Suite struct OutputTests {
  @Test(arguments: WireAPI.allCases) func completeStreamIsOrderedAndTerminal(_ api: WireAPI) throws
  {
    let usage = try TokenUsage(input: 10, cachedInput: 2, output: 3, reasoning: 0)
    var output = WireOutput(api: api, model: "m", id: "fixed", created: 1)
    let first = try output.snapshot("한", usage: usage)
    let last = try output.complete(.init(text: "한국", calls: [], usage: usage))
    let payloads = try events(first + last)
    if api == .responses {
      #expect(payloads.compactMap { $0["sequence_number"]?.integer } == Array(0..<payloads.count))
      #expect(payloads.last?["type"] == .string("response.completed"))
      #expect(
        payloads.last?["response"]?["output"]?.array?.first?["content"]?.array?.first?["text"]
          == .string("한국"))
    } else if api == .chat {
      #expect(last.last == Data("data: [DONE]\n\n".utf8))
    } else {
      #expect(payloads.last?["type"] == .string("message_stop"))
    }
    #expect(throws: (any Error).self) { try output.snapshot("again", usage: usage) }
    #expect(try output.failure(.unavailable("error")).isEmpty)
  }
  @Test func responsesOutputReplaysWithoutLosingTextOrToolIdentity() throws {
    let call = WireToolCall(id: "call_1", name: "lookup", arguments: .object(["key": .string("a")]))
    let output = try WireOutput(api: .responses, model: "local").response(
      .init(text: "I will look it up.", calls: [call], usage: nil))
    let body = JSONValue.object([
      "model": .string("local"),
      "input": .array(
        [.object(["role": .string("user"), "content": .string("lookup")])]
          + (output["output"]?.array ?? [])
          + [
            .object([
              "type": .string("function_call_output"), "call_id": .string("call_1"),
              "output": .string("found"),
            ])
          ]),
    ])
    let request = try InferenceRequest.decode(api: .responses, data: JSONEncoder().encode(body))
    #expect(
      request.entries == [
        .user("lookup"), .assistant("I will look it up."), .toolCall(call),
        .toolResult(id: "call_1", name: "lookup", text: "found"),
      ])
  }
  @Test func combiningScalarIsNotLostByGraphemeDelta() throws {
    var output = WireOutput(api: .responses, model: "m")
    _ = try output.snapshot("e", usage: nil)
    let frames = try output.snapshot("e\u{301}", usage: nil)
    #expect(try events(frames).first?["delta"] == .string("\u{301}"))
  }
  @Test func revisedSnapshotFailsInsteadOfDuplicatingText() throws {
    var output = WireOutput(api: .chat, model: "m")
    _ = try output.snapshot("old", usage: nil)
    #expect(throws: (any Error).self) { try output.snapshot("new", usage: nil) }
    let frames = try output.failure(.unavailable("changed"))
    #expect(!frames.contains(Data("data: [DONE]\n\n".utf8)))
  }
  @Test func messageUsageMustBeMeasuredBeforeStart() throws {
    var output = WireOutput(api: .messages, model: "m")
    #expect(try output.snapshot("held", usage: nil).isEmpty)
    #expect(throws: (any Error).self) {
      try output.complete(.init(text: "held", calls: [], usage: nil))
    }
    let usage = try TokenUsage(input: 8, cachedInput: 2, output: 1, reasoning: 0)
    let payloads = try events(output.complete(.init(text: "held", calls: [], usage: usage)))
    #expect(payloads.first?["message"]?["usage"]?["input_tokens"] == .number(6))
    #expect(payloads.contains { $0["delta"]?["text"] == .string("held") })
  }
  @Test(arguments: [WireAPI.chat, .responses]) func unknownUsageIsOmitted(_ api: WireAPI) throws {
    let out = WireOutput(api: api, model: "m")
    #expect(try out.response(.init(text: "a", calls: [], usage: nil))["usage"] == nil)
  }
  @Test(arguments: WireAPI.allCases) func pendingToolCallsAreNotExecutedOrLost(_ api: WireAPI)
    throws
  {
    let usage = try TokenUsage(input: 5, cachedInput: 0, output: 8, reasoning: 0)
    let calls = [
      WireToolCall(id: "call_1", name: "read", arguments: .object(["path": .string("/a")])),
      WireToolCall(id: "call_2", name: "read", arguments: .object(["path": .string("/b")])),
    ]
    var out = WireOutput(api: api, model: "m", id: "r")
    let frames = try out.complete(.init(text: "", calls: calls, usage: usage))
    let combined = String(decoding: frames.flatMap(Array.init), as: UTF8.self)
    #expect(combined.contains("call_1"))
    #expect(combined.contains("call_2"))
    #expect(combined.contains("/a"))
    #expect(combined.contains("/b"))
    #expect(!combined.contains("tool_result"))
  }
  @Test(arguments: WireAPI.allCases) func failureHasNoSuccessTerminal(_ api: WireAPI) throws {
    var out = WireOutput(api: api, model: "m")
    let body = String(
      decoding: try out.failure(.unavailable("failure")).flatMap(Array.init), as: UTF8.self)
    #expect(!body.contains("response.completed"))
    #expect(!body.contains("message_stop"))
    #expect(!body.contains("[DONE]"))
  }

  @Test func messagesFailurePreservesTypedErrorPayload() throws {
    var out = WireOutput(api: .messages, model: "m")
    let payloads = try events(out.failure(.unavailable("failure")))

    #expect(payloads.first?["type"] == .string("error"))
    #expect(payloads.first?["error"]?["type"] == .string("model_unavailable"))
    #expect(payloads.first?["error"]?["message"] == .string("failure"))
  }
  @Test func emptyAndOversizedOutputFail() throws {
    var out = WireOutput(api: .responses, model: "m")
    #expect(throws: (any Error).self) { try out.complete(.init(text: "", calls: [], usage: nil)) }
    #expect(throws: (any Error).self) {
      try out.snapshot(
        String(repeating: "x", count: ProviderConfiguration.maximumOutputBytes + 1), usage: nil)
    }
  }
  @Test func completedTextIsBoundedForNonStreamingResponses() {
    let tooLarge = String(repeating: "x", count: ProviderConfiguration.maximumOutputBytes + 1)
    let out = WireOutput(api: .responses, model: "m")
    #expect(throws: WireError.self) {
      try out.response(.init(text: tooLarge, calls: [], usage: nil))
    }
  }

  @Test func sharedOutputBudgetHelpersRejectOversizedNativeValues() throws {
    let tooLargeText = String(repeating: "x", count: ProviderConfiguration.maximumOutputBytes + 1)
    #expect(throws: WireError.self) {
      try WireOutput.validateTextOutput(tooLargeText, message: "too large")
    }

    let tooLargeArguments = String(
      repeating: "x", count: ProviderConfiguration.maximumToolArgumentsBytes + 1)
    #expect(throws: WireError.self) {
      try WireOutput.addingToolArgumentBytes(0, json: tooLargeArguments)
    }
    #expect(throws: WireError.self) {
      try WireOutput.addingToolArgumentBytes(Int.max, json: "{}")
    }
    #expect(try WireOutput.addingToolArgumentBytes(1, json: "{}") == 3)
  }

  @Test func toolArgumentOutputIsBoundedBeforeStreamingFramesAreCreated() throws {
    let oversized = String(
      repeating: "x", count: ProviderConfiguration.maximumToolArgumentsBytes + 1)
    let call = WireToolCall(
      id: "call_1", name: "read", arguments: .object(["value": .string(oversized)]))
    var out = WireOutput(api: .responses, model: "m")
    #expect(throws: WireError.self) {
      try out.complete(.init(text: "", calls: [call], usage: nil))
    }
  }

  @Test func invalidUsageFails() {
    #expect(throws: (any Error).self) {
      try TokenUsage(input: -1, cachedInput: 0, output: 1, reasoning: 0)
    }
    #expect(throws: (any Error).self) {
      try TokenUsage(input: 1, cachedInput: 2, output: 1, reasoning: 0)
    }
    #expect(throws: (any Error).self) {
      try TokenUsage(input: 1, cachedInput: 0, output: 1, reasoning: 2)
    }
    #expect(throws: (any Error).self) {
      try TokenUsage(input: Int.max, cachedInput: 0, output: 1, reasoning: 0)
    }
  }

  @Test func largeUsageCountsRemainExactOnWire() throws {
    let usage = try TokenUsage(input: Int.max, cachedInput: 0, output: 0, reasoning: 0)
    let body = try WireOutput(api: .responses, model: "m").response(
      .init(text: "ok", calls: [], usage: usage))

    #expect(body["usage"]?["input_tokens"] == .signedInteger(Int64(Int.max)))
    #expect(body["usage"]?["total_tokens"] == .signedInteger(Int64(Int.max)))
    #expect(try body.jsonString().contains("\"input_tokens\":\(Int.max)"))
  }

  @Test func outputLimitIsNotCompleted() throws {
    let out = WireOutput(api: .responses, model: "m")
    let body = try out.response(.init(text: "partial", calls: [], usage: nil, hitOutputLimit: true))
    #expect(body["status"] == .string("incomplete"))
    #expect(body["incomplete_details"]?["reason"] == .string("max_output_tokens"))
  }
  @Test func separateRequestsHaveSeparateIDsAndSnapshots() throws {
    var a = WireOutput(api: .responses, model: "a")
    var b = WireOutput(api: .responses, model: "b")
    #expect(a.id != b.id)
    _ = try a.snapshot("private A", usage: nil)
    let data = try b.snapshot("private B", usage: nil)
    #expect(!String(decoding: data.flatMap(Array.init), as: UTF8.self).contains("private A"))
  }
}

@Suite struct OutputBoundaryRegressionTests {
  @Test(arguments: WireAPI.allCases) func emptyNonStreamingResultIsRejected(_ api: WireAPI) throws {
    let usage = try TokenUsage(input: 1, cachedInput: 0, output: 0, reasoning: 0)
    let output = WireOutput(api: api, model: "m")
    #expect(throws: (any Error).self) {
      try output.response(.init(text: "", calls: [], usage: usage))
    }
  }

  @Test(arguments: WireAPI.allCases) func invalidToolIdentityOrArgumentsIsRejected(_ api: WireAPI)
    throws
  {
    let usage = try TokenUsage(input: 1, cachedInput: 0, output: 1, reasoning: 0)
    let call = WireToolCall(id: "a", name: "lookup", arguments: .object([:]))
    let invalidCalls: [[WireToolCall]] = [
      [.init(id: "", name: "lookup", arguments: .object([:]))],
      [.init(id: "a", name: "", arguments: .object([:]))],
      [.init(id: "a", name: "lookup", arguments: .array([]))],
      [call, call],
    ]
    for calls in invalidCalls {
      let result = InferenceResult(text: "", calls: calls, usage: usage)
      let output = WireOutput(api: api, model: "m")
      #expect(throws: (any Error).self) { try output.response(result) }
      var stream = WireOutput(api: api, model: "m")
      #expect(throws: (any Error).self) { try stream.complete(result) }
    }
  }
}
