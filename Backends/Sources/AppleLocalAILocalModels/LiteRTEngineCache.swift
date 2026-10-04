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
  @preconcurrency import LiteRTLM

  /// Process-wide cache of one lazily initialized engine per configuration.
  @available(iOS 27.0, macOS 27.0, *)
  final class EngineCache: @unchecked Sendable {
    static let shared = EngineCache()

    private let lock = NSLock()
    private var engines: [LiteRTLMExecutor.Configuration: LazyEngine] = [:]
    private var purgeGeneration: UInt64 = 0
    private var activePurge: Purge?

    private struct Purge: Sendable {
      let generation: UInt64
      let task: Task<Void, Never>
    }

    func engine(for configuration: LiteRTLMExecutor.Configuration) -> LazyEngine {
      lock.lock()
      defer { lock.unlock() }
      if let engine = engines[configuration] { return engine }
      let engine = LazyEngine(configuration: configuration, admissionBarrier: activePurge?.task)
      engines[configuration] = engine
      return engine
    }

    func purgeAll() async {
      let purge = startPurge()
      await purge.task.value
      finishPurge(generation: purge.generation)
    }

    private func startPurge() -> Purge {
      lock.lock()
      defer { lock.unlock() }
      purgeGeneration &+= 1
      let generation = purgeGeneration
      let previousPurge = activePurge?.task
      let all = Array(engines.values)
      engines.removeAll()
      let task = Task<Void, Never> {
        for engine in all { await engine.beginDraining() }
        if let previousPurge { await previousPurge.value }
        for engine in all { await engine.release() }
      }
      activePurge = Purge(generation: generation, task: task)
      return Purge(generation: generation, task: task)
    }

    private func finishPurge(generation: UInt64) {
      lock.lock()
      defer { lock.unlock() }
      if activePurge?.generation == generation {
        activePurge = nil
      }
    }
  }

  /// Defers native engine initialization until an async operation needs it.
  @available(iOS 27.0, macOS 27.0, *)
  actor LazyEngine {
    private let configuration: LiteRTLMExecutor.Configuration
    private var engineTask: Task<Engine, Error>?
    private var warmupTask: Task<Void, Error>?
    private var useState = LiteRTEngineUseState()
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let admissionBarrier: Task<Void, Never>?

    init(
      configuration: LiteRTLMExecutor.Configuration,
      admissionBarrier: Task<Void, Never>? = nil
    ) {
      self.configuration = configuration
      self.admissionBarrier = admissionBarrier
    }

    func ready() async throws -> Engine {
      try Task.checkCancellation()
      let task: Task<Engine, Error>
      if let existing = engineTask {
        task = existing
      } else {
        let configuration = self.configuration
        task = Task {
          try Task.checkCancellation()
          let created = Engine(engineConfig: configuration.engineConfig)
          try await created.initialize()
          try Task.checkCancellation()
          return created
        }
        engineTask = task
      }

      let engine: Engine
      do {
        engine = try await task.value
      } catch {
        if engineTask == task { engineTask = nil }
        throw error
      }
      try Task.checkCancellation()
      guard engineTask == task else { throw CancellationError() }
      return engine
    }

    /// Acquires a lease that covers the complete native conversation. A cache
    /// purge marks this instance draining before waiting, so a new operation
    /// cannot race an eviction or silently resurrect an old cache entry.
    func acquire() async throws -> Engine {
      if let admissionBarrier {
        await admissionBarrier.value
        try Task.checkCancellation()
      }
      try useState.acquire()
      do {
        let engine = try await ready()
        // `release()` may have started while initialization was suspended.
        guard !useState.isDraining else { throw CancellationError() }
        return engine
      } catch {
        releaseUse()
        throw error
      }
    }

    func beginDraining() {
      useState.beginDraining()
      engineTask?.cancel()
      warmupTask?.cancel()
    }

    func releaseUse() {
      let settled = useState.release()
      guard useState.isDraining, settled else { return }
      let waiters = drainWaiters
      drainWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }

    func prewarmed() async throws {
      let engine = try await acquire()
      do {
        let task: Task<Void, Error>
        if let existing = warmupTask {
          task = existing
        } else {
          task = Task {
            try Task.checkCancellation()
            let conversation = try await engine.createConversation()
            try await withTaskCancellationHandler {
              try Task.checkCancellation()
              for try await _ in conversation.sendMessageStream(Message("Hi")) {
                try Task.checkCancellation()
              }
              try Task.checkCancellation()
            } onCancel: {
              do { try conversation.cancel() } catch {
                liteRTLogger.error(
                  "LiteRT warmup cancellation failed: \(String(describing: error))")
              }
            }
          }
          warmupTask = task
        }

        do {
          try await task.value
        } catch {
          if warmupTask == task { warmupTask = nil }
          throw error
        }
        try Task.checkCancellation()
      } catch {
        releaseUse()
        throw error
      }
      releaseUse()
    }

    func release() async {
      beginDraining()
      let loading = engineTask
      let warming = warmupTask
      if !useState.isSettled {
        await withCheckedContinuation { continuation in
          drainWaiters.append(continuation)
        }
      }
      if let warming { _ = await warming.result }
      if let loading { _ = await loading.result }
      if engineTask == loading { engineTask = nil }
      if warmupTask == warming { warmupTask = nil }
    }
  }

#endif
