#if os(macOS)

  import AppleLocalAI
  import Foundation
  import FoundationModels

  /// A read-only presentation of the Foundation Models transcript.
  /// The native session remains the sole owner of conversation history.
  enum ConversationHistoryProjection {
    struct Snapshot {
      let messages: [Message]
      let omittedEntryCount: Int
    }

    struct Message: Identifiable {
      enum Content {
        case user(prompt: String, attachments: [Attachment])
        case assistant(String)
        case tool(title: String, detail: String)
        case unsupported
      }

      let id: String
      let content: Content
    }

    struct Attachment: Identifiable {
      let id: String
      let title: String
    }

    static func priorEntries(
      in history: [Transcript.Entry],
      beforeEntryCount: Int
    ) -> [Transcript.Entry] {
      Array(history.prefix(min(max(0, beforeEntryCount), history.count)))
    }

    static func project(_ history: [Transcript.Entry], limit: Int) -> Snapshot {
      let displayableEntries = history.filter(isDisplayable)
      let boundedEntries = AppleLocalAIHistoryPolicy.recentEntries(max(1, limit)).project(
        displayableEntries,
        omitEmptyPrompt: true
      )

      return Snapshot(
        messages: boundedEntries.compactMap(message(for:)),
        omittedEntryCount: max(0, displayableEntries.count - boundedEntries.count)
      )
    }

    private static func isDisplayable(_ entry: Transcript.Entry) -> Bool {
      switch entry {
      case .instructions, .reasoning:
        false
      case .prompt(let prompt):
        prompt.segments.contains { segment in
          switch segment {
          case .text(let value): !value.content.isEmpty
          case .structure, .attachment: true
          @unknown default: true
          }
        }
      case .response(let response):
        !response.segments.isEmpty
      case .toolCalls(let calls):
        !calls.isEmpty
      case .toolOutput(let output):
        !output.segments.isEmpty
      @unknown default:
        true
      }
    }

    static func latestUserPrompt(in history: [Transcript.Entry]) -> String? {
      for entry in history.reversed() {
        guard case .prompt(let prompt) = entry else { continue }
        guard !containsUnsupportedSegment(prompt.segments) else { return nil }
        let text = text(in: prompt.segments)
        if !text.isEmpty { return text }
      }
      return nil
    }

    private static func message(for entry: Transcript.Entry) -> Message? {
      switch entry {
      case .instructions, .reasoning:
        return nil

      case .prompt(let prompt):
        guard !containsUnsupportedSegment(prompt.segments) else {
          return Message(id: entry.id, content: .unsupported)
        }
        let attachments = prompt.segments.compactMap(attachment(from:))
        let text = text(in: prompt.segments)
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return Message(id: entry.id, content: .user(prompt: text, attachments: attachments))

      case .response(let response):
        guard !containsUnsupportedSegment(response.segments) else {
          return Message(id: entry.id, content: .unsupported)
        }
        let text = displayText(in: response.segments)
        guard !text.isEmpty else { return nil }
        return Message(id: entry.id, content: .assistant(text))

      case .toolCalls(let calls):
        let names = calls.map(\.toolName).joined(separator: " · ")
        guard !names.isEmpty else { return nil }
        return Message(id: entry.id, content: .tool(title: "도구 사용", detail: names))

      case .toolOutput(let output):
        guard !containsUnsupportedSegment(output.segments) else {
          return Message(id: entry.id, content: .unsupported)
        }
        let detail = displayText(in: output.segments)
        guard !detail.isEmpty else { return nil }
        return Message(
          id: entry.id,
          content: .tool(title: output.toolName + " 결과", detail: detail)
        )
      @unknown default:
        return Message(id: entry.id, content: .unsupported)
      }
    }

    private static func containsUnsupportedSegment(_ segments: [Transcript.Segment]) -> Bool {
      segments.contains { segment in
        switch segment {
        case .text, .structure, .attachment: false
        @unknown default: true
        }
      }
    }

    private static func text(in segments: [Transcript.Segment]) -> String {
      segments.compactMap { segment in
        switch segment {
        case .text(let value): value.content
        case .structure(let value): value.content.jsonString
        case .attachment: nil
        @unknown default: nil
        }
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    }

    private static func displayText(in segments: [Transcript.Segment]) -> String {
      segments.compactMap { segment in
        switch segment {
        case .text(let value): value.content
        case .structure(let value): value.content.jsonString
        case .attachment(let value): value.label ?? "이미지 첨부"
        @unknown default: nil
        }
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    }

    private static func attachment(from segment: Transcript.Segment) -> Attachment? {
      guard case .attachment(let value) = segment else { return nil }
      guard case .image(let image) = value.content else { return nil }

      let title = image.url?.lastPathComponent ?? value.label ?? "이미지"
      return Attachment(id: value.id, title: title)
    }
  }

#endif
