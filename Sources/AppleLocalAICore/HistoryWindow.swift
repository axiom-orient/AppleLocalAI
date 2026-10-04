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
      // A response between tool cycles can also be the first retained entry.
      // Only inspect this turn: tools after the next prompt have their owner.
      let nextPrompt = entries[start...].firstIndex(where: { $0 == .prompt }) ?? entries.count
      if entries[start..<nextPrompt].contains(where: { $0 == .toolCalls || $0 == .toolOutput }) {
        start = entries[...start].lastIndex(where: { $0 == .prompt }) ?? 0
      }
    }
    return start..<entries.count
  }
}
