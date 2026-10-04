import AppleLocalAICore
import FoundationModels

extension AppleLocalAIHistoryPolicy {
  /// Provider-specific reasoning is retained by the canonical native transcript,
  /// but omitted from replay when a profile invokes another model.
  public func project(
    _ history: [Transcript.Entry],
    omitEmptyPrompt: Bool = false
  ) -> [Transcript.Entry] {
    var portable = history.filter { entry in
      if case .reasoning = entry { return false }
      return true
    }
    if omitEmptyPrompt,
      case .prompt(let trigger) = portable.last,
      trigger.segments.allSatisfy({
        if case .text(let text) = $0 { text.content.isEmpty } else { false }
      })
    {
      portable.removeLast()
    }

    switch self {
    case .full:
      return portable
    case .recentEntries(let limit):
      let kinds: [HistoryEntryKind] = portable.map { entry in
        switch entry {
        case .prompt: .prompt
        case .toolCalls: .toolCalls
        case .toolOutput: .toolOutput
        default: .other
        }
      }
      return Array(portable[HistoryWindow.retainedRange(in: kinds, limit: limit)])
    }
  }
}
