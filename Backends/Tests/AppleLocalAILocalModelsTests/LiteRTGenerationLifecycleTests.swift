import Foundation
import Synchronization
import Testing

@testable import AppleLocalAILocalModels

#if canImport(LiteRTLM)
  @preconcurrency import LiteRTLM
#endif

@Test func engineReleaseWaitsForAllActiveUsesAndRejectsNewUses() throws {
  var state = LiteRTEngineUseState()
  try state.acquire()
  try state.acquire()
  state.beginDraining()

  #expect(state.activeUses == 2)
  #expect(!state.isSettled)
  #expect(throws: LiteRTEngineUseError.draining) { try state.acquire() }

  let firstRelease = state.release()
  #expect(!firstRelease)
  #expect(!state.isSettled)
  let finalRelease = state.release()
  #expect(finalRelease)
  #expect(state.isSettled)
}

#if canImport(LiteRTLM)
  @Test func newEngineAdmissionWaitsForCachePurgeBarrier() async throws {
    let release = AsyncStream<Void>.makeStream()
    let barrier = Task<Void, Never> {
      for await _ in release.stream {}
    }
    let nativeConfiguration = try EngineConfig(
      modelPath: "/private/var/empty/applelocalai-missing-model.litertlm")
    let configuration = LiteRTLMExecutor.Configuration(engineConfig: nativeConfiguration)
    let engine = LazyEngine(configuration: configuration, admissionBarrier: barrier)
    let completed = Mutex(false)

    let pending = Task {
      defer { completed.withLock { $0 = true } }
      do {
        _ = try await engine.acquire()
      } catch {}
    }

    for _ in 0..<100 { await Task.yield() }
    #expect(!completed.withLock { $0 })

    release.continuation.finish()
    await pending.value
    #expect(completed.withLock { $0 })
  }
#endif

@Test func outputByteLimitStopsNativeWorkWithoutCancellingTheTask() async throws {
  let cancellations = Mutex(0)
  await #expect(throws: LiteRTFMError.self) {
    try await LiteRTGenerationLifecycle.run {
      var buffer = try LiteRTResponseBuffer(maximumBytes: 4)
      try buffer.append("한")
      try buffer.append("글")
    } cancel: {
      cancellations.withLock { $0 += 1 }
    }
  }
  #expect(!Task.isCancelled)
  #expect(cancellations.withLock { $0 } == 1)
}

@Test func bufferedResponseAcceptsItsExactUTF8ByteLimit() throws {
  var buffer = try LiteRTResponseBuffer(maximumBytes: 4)
  try buffer.append("한")
  try buffer.append("!")
  try buffer.append("")
  #expect(buffer.text == "한!")
  #expect(throws: LiteRTFMError.self) { try buffer.append("x") }
  #expect(buffer.text == "한!")
}

@Test func bufferedResponseMergesManyFragmentsWithoutChangingContent() throws {
  var buffer = try LiteRTResponseBuffer(maximumBytes: 2_048)
  for _ in 0..<2_048 { try buffer.append("a") }
  #expect(buffer.text == String(repeating: "a", count: 2_048))
}

@Test func streamedResponseBudgetAcceptsItsExactUTF8ByteLimit() throws {
  var budget = try LiteRTResponseBuffer(maximumBytes: 4)
  try budget.record("한")
  try budget.record("!")
  #expect(budget.text.isEmpty)
  #expect(throws: LiteRTFMError.self) { try budget.record("x") }
}

@Test func generationFailurePreservesItsOriginalError() async {
  enum ProbeError: Error { case nativeFailure }
  let cancellations = Mutex(0)
  await #expect(throws: ProbeError.self) {
    try await LiteRTGenerationLifecycle.run {
      throw ProbeError.nativeFailure
    } cancel: {
      cancellations.withLock { $0 += 1 }
    }
  }
  #expect(cancellations.withLock { $0 } == 1)
}

@Test func successfulGenerationDoesNotCancelNativeWork() async throws {
  let cancellations = Mutex(0)
  try await LiteRTGenerationLifecycle.run {
  } cancel: {
    cancellations.withLock { $0 += 1 }
  }
  #expect(cancellations.withLock { $0 } == 0)
}

@Test func taskCancellationStopsNativeWorkOnce() async throws {
  let cancellations = Mutex(0)
  let started = AsyncStream<Void>.makeStream()
  let task = Task {
    try await LiteRTGenerationLifecycle.run {
      started.continuation.yield(())
      try await Task.sleep(for: .seconds(5))
    } cancel: {
      cancellations.withLock { $0 += 1 }
    }
  }
  var iterator = started.stream.makeAsyncIterator()
  _ = await iterator.next()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(cancellations.withLock { $0 } == 1)
  started.continuation.finish()
}

@Test func negativeOutputByteLimitIsRejectedBeforeGeneration() {
  #expect(throws: LiteRTFMError.self) { try LiteRTResponseBuffer(maximumBytes: -1) }
}

@Test func zeroOutputByteLimitAcceptsOnlyEmptyOutput() throws {
  var buffer = try LiteRTResponseBuffer(maximumBytes: 0)
  try buffer.append("")
  #expect(buffer.text.isEmpty)
  #expect(throws: LiteRTFMError.self) { try buffer.append("x") }
}

@Test func emptyLiteRTResponseFailsClosed() throws {
  var buffer = try LiteRTResponseBuffer(maximumBytes: 6)
  #expect(throws: LiteRTFMError.self) { try buffer.requireNonEmptyResponse() }
  try buffer.record("answer")
  try buffer.requireNonEmptyResponse()
}
