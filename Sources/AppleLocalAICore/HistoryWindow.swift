public enum HistoryEntryKind: Sendable {
  case prompt
  case toolCalls
  case toolOutput
  case other
}

public enum HistoryWindow {
  /// Retains a suffix without starting inside a tool round trip.
  /// The limit is a target: the window may grow backward to keep the prompt
  /// that initiated retained tool calls and outputs.
  public static func retainedRange(in entries: [HistoryEntryKind], limit: Int) -> Range<Int> {
    var start = max(0, entries.count - max(1, limit))
    if start < entries.count {
      switch entries[start] {
      case .toolCalls, .toolOutput:
        start = entries[...start].lastIndex(where: { $0 == .prompt }) ?? 0
      case .prompt, .other:
        break
      }
    }
    return start..<entries.count
  }
}
