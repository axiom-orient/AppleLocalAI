import Testing

@testable import AppleLocalAICore

@Test func keepsToolRoundTripWithInitiatingPrompt() {
  let entries: [HistoryEntryKind] = [.prompt, .other, .prompt, .toolCalls, .toolOutput]
  #expect(HistoryWindow.retainedRange(in: entries, limit: 2) == 2..<5)
}

@Test func regularSuffixUsesRequestedLimit() {
  let entries: [HistoryEntryKind] = [.prompt, .other, .prompt, .other]
  #expect(HistoryWindow.retainedRange(in: entries, limit: 2) == 2..<4)
}

@Test func emptyAndOrdinarySuffix() {
  #expect(HistoryWindow.retainedRange(in: [], limit: 1) == 0..<0)
  #expect(
    HistoryWindow.retainedRange(in: [.prompt, .other, .prompt], limit: 2) == 1..<3)
}

@Test func parallelOutputsKeepInitiatingPromptAndAllCalls() {
  let entries: [HistoryEntryKind] = [
    .prompt, .other, .prompt, .toolCalls, .toolOutput, .toolOutput,
  ]
  for limit in 1...4 {
    #expect(HistoryWindow.retainedRange(in: entries, limit: limit) == 2..<6)
  }
}

@Test func pendingCallsAreNotSilentlyRemoved() {
  #expect(HistoryWindow.retainedRange(in: [.prompt, .toolCalls], limit: 1) == 0..<2)
}

@Test func repeatedToolCyclesRemainInOneTurn() {
  let entries: [HistoryEntryKind] = [
    .prompt, .toolCalls, .toolOutput, .other, .toolCalls, .toolOutput,
  ]
  #expect(HistoryWindow.retainedRange(in: entries, limit: 1) == 0..<6)
}

@Test func newUserTurnDoesNotRetainOldToolTurn() {
  let entries: [HistoryEntryKind] = [.prompt, .toolCalls, .toolOutput, .other, .prompt]
  #expect(HistoryWindow.retainedRange(in: entries, limit: 1) == 4..<5)
}

@Test func missingPromptIsNotInvented() {
  #expect(HistoryWindow.retainedRange(in: [.toolCalls, .toolOutput], limit: 1) == 0..<2)
}
