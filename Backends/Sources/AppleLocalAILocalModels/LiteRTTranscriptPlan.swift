// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Parts of this implementation were originally authored by @john-rocky and
// ported from https://github.com/john-rocky/swift-litert-lm/tree/main.

#if canImport(FoundationModels) && compiler(>=6.4)

  import Foundation
  import FoundationModels
  @preconcurrency import LiteRTLM

  struct LiteRTTranscriptPlan {
    let systemMessage: Message?
    let history: [Message]
    let prompt: Message
  }

  enum LiteRTTranscriptPlanner {
    static let maximumTranscriptEntries = 4_096
    static let maximumToolDefinitions = 128
    static let maximumPromptBytes = 1_048_576

    private static let schemaPromptPrefix =
      "\n\nRespond with ONLY a JSON object that conforms to this JSON schema. "
      + "Output valid JSON and nothing else:\n"

    static func make(
      from transcript: Transcript,
      schemaJSON: String?,
      tools: [Transcript.ToolDefinition]
    ) throws -> LiteRTTranscriptPlan {
      guard transcript.count <= maximumTranscriptEntries else {
        throw LiteRTFMError.unsupported(
          "LiteRT transcripts cannot contain more than "
            + String(maximumTranscriptEntries) + " entries.")
      }
      guard tools.count <= maximumToolDefinitions else {
        throw LiteRTFMError.unsupported(
          "LiteRT requests cannot contain more than "
            + String(maximumToolDefinitions) + " tool definitions.")
      }
      var inputBytes = 0
      if let schemaJSON, !schemaJSON.isEmpty {
        try addInputBytes(schemaJSON.utf8.count, to: &inputBytes)
      }
      let entries = Array(transcript)
      guard
        let terminalIndex = entries.lastIndex(where: {
          if case .reasoning = $0 { return false }
          return true
        })
      else {
        throw LiteRTFMError.noPrompt
      }
      let triggerIndex: Int
      switch entries[terminalIndex] {
      case .prompt, .toolOutput:
        triggerIndex = terminalIndex
      default:
        throw LiteRTFMError.unsupported(
          "LiteRT generation requires the transcript to end with a prompt or tool output.")
      }

      var systemText: [String] = []
      if !tools.isEmpty {
        let toolText = try toolInstructions(tools)
        try addInputBytes(toolText.utf8.count, to: &inputBytes)
        systemText.append(toolText)
      }
      var history: [Message] = []
      var trigger: Message?
      var instructionsClosed = false

      for (index, entry) in entries.enumerated() {
        let isTrigger = index == triggerIndex
        switch entry {
        case .instructions(let instructions):
          guard !instructionsClosed else {
            throw LiteRTFMError.unsupported(
              "LiteRT instructions must remain before the conversation history.")
          }
          let instructionText = try text(of: instructions.segments)
          try addInputBytes(
            instructionText.utf8.count + (systemText.isEmpty ? 0 : 1), to: &inputBytes)
          systemText.append(instructionText)
        case .prompt(let prompt):
          instructionsClosed = true
          let promptContents = try contents(of: prompt.segments)
          try addInputBytes(promptContents.byteCount, to: &inputBytes)
          var contents = promptContents.contents
          if isTrigger, let schemaJSON, !schemaJSON.isEmpty {
            contents.append(.text(schemaPromptPrefix + schemaJSON))
            try addInputBytes(schemaPromptPrefix.utf8.count, to: &inputBytes)
          }
          let message = Message(contents: contents, role: .user)
          if isTrigger { trigger = message } else { history.append(message) }
        case .response(let response):
          instructionsClosed = true
          let responseText = try text(of: response.segments, allowingStructuredResponse: true)
          try addInputBytes(responseText.utf8.count, to: &inputBytes)
          history.append(
            Message(contents: [.text(responseText)], role: .model))
        case .toolOutput(let output):
          instructionsClosed = true
          let result = try text(of: output.segments)
          try addInputBytes(result.utf8.count, to: &inputBytes)
          try addInputBytes(output.toolName.utf8.count, to: &inputBytes)
          try addInputBytes(output.id.utf8.count, to: &inputBytes)
          let message = Message(
            contents: [.toolResponse(name: output.toolName, response: result, id: output.id)],
            role: .tool)
          if isTrigger { trigger = message } else { history.append(message) }
        case .toolCalls(let calls):
          instructionsClosed = true
          let nativeCalls = try calls.map { call -> LiteRTLM.ToolCall in
            let argumentsJSON = call.arguments.jsonString
            try addInputBytes(argumentsJSON.utf8.count, to: &inputBytes)
            try addInputBytes(call.toolName.utf8.count, to: &inputBytes)
            try addInputBytes(call.id.utf8.count, to: &inputBytes)
            guard
              let arguments = try JSONSerialization.jsonObject(
                with: Data(argumentsJSON.utf8)) as? [String: Any]
            else {
              throw LiteRTFMError.invalidToolCall("Historical tool arguments must be an object")
            }
            return LiteRTLM.ToolCall(name: call.toolName, id: call.id, arguments: arguments)
          }
          guard !nativeCalls.isEmpty else {
            throw LiteRTFMError.invalidToolCall("Historical tool call group must not be empty")
          }
          history.append(Message(contents: [], role: .model, toolCalls: nativeCalls))
        case .reasoning:
          break
        @unknown default:
          throw LiteRTFMError.unsupported("Unsupported native transcript entry or sampling mode")
        }
      }

      guard let prompt = trigger else { throw LiteRTFMError.noPrompt }
      let system = systemText.joined(separator: "\n").trimmingCharacters(
        in: .whitespacesAndNewlines)
      return LiteRTTranscriptPlan(
        systemMessage: system.isEmpty ? nil : Message(system, role: .system),
        history: history,
        prompt: prompt)
    }

    private static func toolInstructions(_ tools: [Transcript.ToolDefinition]) throws -> String {
      var lines = ["You can call tools to help answer the user. Available tools:"]
      var byteCount = lines[0].utf8.count
      for tool in tools {
        let parameters = try encodeSchema(tool.parameters)
        let line = "- \(tool.name): \(tool.description). arguments schema: \(parameters)"
        try addInputBytes(line.utf8.count + 1, to: &byteCount)
        lines.append(line)
      }
      let suffix =
        "To call a tool, reply with ONLY this JSON and nothing else: "
        + "{\"tool_call\": {\"name\": \"<tool name>\", \"arguments\": { ... }}}. "
        + "If no tool is needed, answer the user directly."
      try addInputBytes(suffix.utf8.count + 1, to: &byteCount)
      lines.append(suffix)
      return lines.joined(separator: "\n")
    }

    private static func addInputBytes(_ bytes: Int, to total: inout Int) throws {
      let (next, overflow) = total.addingReportingOverflow(bytes)
      guard !overflow, next <= maximumPromptBytes else {
        throw LiteRTFMError.unsupported(
          "LiteRT prompt input exceeded its "
            + String(maximumPromptBytes) + "-byte UTF-8 limit")
      }
      total = next
    }

    private static func text(
      of segments: [Transcript.Segment],
      allowingStructuredResponse: Bool = false
    ) throws -> String {
      try segments.map { segment in
        switch segment {
        case .text(let text):
          return text.content
        case .structure(let structure) where allowingStructuredResponse:
          // Foundation Models commits guided output as a structured response.
          // Replay that generated JSON without accepting structured user input.
          return structure.content.jsonString
        default:
          throw LiteRTFMError.unsupported(
            "LiteRT compatibility adapter only supports text transcript segments")
        }
      }.joined(separator: " ")
    }

    static func encodeSchema(_ schema: GenerationSchema) throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(schema)
      return String(data: data, encoding: .utf8) ?? ""
    }

    private static func contents(of segments: [Transcript.Segment]) throws -> (
      contents: [Content], byteCount: Int
    ) {
      var output: [Content] = []
      var byteCount = 0
      for segment in segments {
        switch segment {
        case .text(let text):
          if !text.content.isEmpty {
            try addInputBytes(text.content.utf8.count, to: &byteCount)
            output.append(.text(text.content))
          }
        case .attachment(let attachment):
          guard case .image(let image) = attachment.content else {
            throw LiteRTFMError.unsupported(
              "LiteRT compatibility adapter only supports image attachments")
          }
          guard let png = pngData(from: image.cgImage) else {
            throw LiteRTFMError.unsupported("Image attachment could not be encoded as PNG")
          }
          try addInputBytes(png.count, to: &byteCount)
          output.append(.imageData(png))
        case .structure:
          throw LiteRTFMError.unsupported(
            "LiteRT compatibility adapter does not support structured transcript segments")
        @unknown default:
          throw LiteRTFMError.unsupported("Unsupported Foundation Models transcript segment")
        }
      }
      return (output.isEmpty ? [.text("")] : output, byteCount)
    }
  }

#endif
