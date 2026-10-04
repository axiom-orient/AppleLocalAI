import AppleLocalAIHost
import Foundation
import Testing

@Suite("Conversation state contract")
struct ConversationStateTests {
  @Test func beginNormalizesPromptAndOwnsOnlyValueState() {
    let image = ConversationImage(url: URL(fileURLWithPath: "/tmp/note.png"))
    let result = ConversationState.empty.applying(
      .begin(prompt: "  summarize this  ", image: image)
    )

    guard case .success(let state) = result else {
      Issue.record("begin should produce a responding state")
      return
    }

    #expect(state.isResponding)
    #expect(state.submittedTurn?.prompt == "summarize this")
    #expect(state.submittedTurn?.image == image)
    #expect(state.responseText.isEmpty)
  }

  @Test func invalidPromptAndAnswerCannotBecomeState() {
    let emptyPrompt = ConversationState.empty.applying(.begin(prompt: " \n ", image: nil))
    guard case .failure(.emptyPrompt) = emptyPrompt else {
      Issue.record("an empty prompt must be rejected")
      return
    }

    let responding = ConversationState.empty.applying(.begin(prompt: "hello", image: nil))
    guard case .success(let state) = responding else {
      Issue.record("begin should succeed")
      return
    }

    let emptyAnswer = state.applying(.finish(answer: " \n "))
    guard case .failure(.emptyAnswer) = emptyAnswer else {
      Issue.record("an empty final answer must be rejected")
      return
    }
  }

  @Test func cancellationIsAnExplicitIdempotentTransition() {
    let started = ConversationState.empty.applying(.begin(prompt: "hello", image: nil))
    guard case .success(let responding) = started else {
      Issue.record("begin should succeed")
      return
    }

    let cancelling = responding.applying(.requestCancellation)
    guard case .success(let cancellingState) = cancelling else {
      Issue.record("a responding state should enter cancellation")
      return
    }
    #expect(cancellingState.isCancelling)
    #expect(cancellingState.applying(.requestCancellation) == .failure(.responseNotActive))

    let settled = cancellingState.applying(.settleCancellation)
    guard case .success(let cancelled) = settled else {
      Issue.record("cancellation should settle")
      return
    }
    #expect(cancelled.wasCancelled)
    #expect(cancelled.applying(.settleCancellation) == .failure(.cancellationNotActive))
  }

  @Test func failuresPreserveTheirOriginWithoutOptionalPromptState() {
    let beforeStart = ConversationState.empty.applying(
      .failBeforeStart(message: "model is unavailable")
    )
    guard case .success(let state) = beforeStart else {
      Issue.record("preflight failure should be representable")
      return
    }
    #expect(state.submittedTurn?.prompt == nil)
    #expect(state.errorMessage == "model is unavailable")

    let withInput = ConversationState.empty.applying(
      .failWithInput(prompt: "hello", image: nil, message: "request failed")
    )
    guard case .success(let failed) = withInput else {
      Issue.record("request failure should preserve its turn")
      return
    }
    #expect(failed.submittedTurn?.prompt == "hello")
    #expect(failed.errorMessage == "request failed")
  }
}
