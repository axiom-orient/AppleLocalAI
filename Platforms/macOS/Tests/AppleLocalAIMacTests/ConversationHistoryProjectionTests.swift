import FoundationModels
import Testing

@testable import AppleLocalAIMac

@Suite("Conversation history presentation")
struct ConversationHistoryProjectionTests {
  @Test func recentProjectionUsesNativeEntryIdsAndReportsHiddenHistory() {
    let entries = [
      prompt("prompt-1", "첫 번째 질문"),
      response("response-1", "첫 번째 답변"),
      prompt("prompt-2", "두 번째 질문"),
      response("response-2", "두 번째 답변"),
      prompt("prompt-3", "세 번째 질문"),
      response("response-3", "세 번째 답변"),
    ]

    let projection = ConversationHistoryProjection.project(entries, limit: 2)

    #expect(projection.messages.map(\.id) == ["prompt-3", "response-3"])
    #expect(projection.omittedEntryCount == 4)
    #expect(ConversationHistoryProjection.latestUserPrompt(in: entries) == "세 번째 질문")
  }

  @Test func currentTurnBoundaryExcludesOnlyEntriesAddedAfterTheTurnBegan() {
    let entries = [
      prompt("prompt-1", "이전 질문"),
      response("response-1", "이전 답변"),
      prompt("prompt-2", "현재 질문"),
      response("response-2", "현재 응답"),
    ]

    let priorEntries = ConversationHistoryProjection.priorEntries(
      in: entries,
      beforeEntryCount: 2
    )

    #expect(priorEntries.map(\.id) == ["prompt-1", "response-1"])
  }

  @Test func recentProjectionExpandsToKeepToolRoundTripTogether() throws {
    let call = Transcript.ToolCall(
      id: "call-1",
      toolName: "lookup",
      arguments: try GeneratedContent(json: "{}")
    )
    let entries: [Transcript.Entry] = [
      prompt("prompt-1", "이전 질문"),
      response("response-1", "이전 답변"),
      prompt("prompt-2", "검색해줘"),
      .toolCalls(Transcript.ToolCalls(id: "calls-2", [call])),
      .toolOutput(
        Transcript.ToolOutput(
          id: "output-2",
          toolName: "lookup",
          segments: [.text(Transcript.TextSegment(content: "검색 결과"))]
        )),
      response("response-2", "요약 답변"),
    ]

    let projection = ConversationHistoryProjection.project(entries, limit: 2)

    #expect(
      projection.messages.map(\.id)
        == ["prompt-2", "calls-2", "output-2", "response-2"])
    #expect(projection.omittedEntryCount == 2)
  }

  private func prompt(_ id: String, _ text: String) -> Transcript.Entry {
    .prompt(
      Transcript.Prompt(
        id: id,
        segments: [.text(Transcript.TextSegment(content: text))]
      ))
  }

  private func response(_ id: String, _ text: String) -> Transcript.Entry {
    .response(
      Transcript.Response(
        id: id,
        segments: [.text(Transcript.TextSegment(content: text))]
      ))
  }
}
