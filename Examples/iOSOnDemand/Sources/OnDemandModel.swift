import AppleLocalAI
import AppleLocalAILEAP
import Foundation
import OSLog
import Observation

/// The sample owns UI work and native residency. The package session is the
/// only conversation owner; no provider registry or second transcript is used.
@MainActor
@Observable
final class OnDemandModel {
  var prompt = "Say hello in one short sentence."
  private(set) var result = ""
  private(set) var status = "실행하면 모델을 준비합니다."
  private(set) var progress: Double?
  private(set) var errorMessage: String?
  private(set) var evidence: VerificationEvidence?
  private(set) var isLoaded = false
  private(set) var isStopping = false
  var isWorking: Bool { operation != nil }

  @ObservationIgnored private var runtime: AppleLocalAILEAPRuntime?
  @ObservationIgnored private var session: AppleLocalAISession?
  private var operation: Task<Void, Never>?
  @ObservationIgnored private var operationID: UUID?
  @ObservationIgnored private var preparing = false
  @ObservationIgnored private var releaseAfterStop = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.applelocalai.iosondemand", category: "verification")

  func run() {
    guard operation == nil else { return }
    let text = prompt
    result = ""
    begin {
      let id = try self.currentID()
      let session = try await self.loadSession(id: id)
      try Task.checkCancellation()
      self.status = "응답 생성 중"
      let response = try await session.stream(AppleLocalAIRequest(text: text)) { snapshot in
        guard self.operationID == id, !self.isStopping else { return }
        self.result = snapshot.text
      }
      try Self.requireReadable(response.text)
      self.result = response.text
      self.status = "완료 · 모델이 메모리에 있습니다."
    }
  }

  func stop() {
    guard operation != nil else { return }
    isStopping = true
    status = "중지 처리 중"
    session?.cancel()
    operation?.cancel()
  }

  func stopAndRelease() {
    if operation != nil {
      releaseAfterStop = true
      stop()
    } else {
      releaseMemory()
    }
  }

  func releaseMemory() {
    guard operation == nil, isLoaded else { return }
    begin {
      try await self.unload()
      self.status = "메모리 해제 완료 · 다운로드 파일은 보관됩니다."
    }
  }

  func startVerification() {
    guard operation == nil else { return }
    evidence = nil
    begin {
      var report = VerificationEvidence()
      do {
        // Replace an earlier result atomically before any download or native work.
        try self.persist(report)
        try await self.verify(into: &report)
        report.outcome = "PASS"
        try self.persist(report)
        self.status = "실제 온디바이스 검증 완료 · 메모리 해제됨"
      } catch {
        report.outcome = "FAIL"
        report.error = String(describing: error)
        self.evidence = report
        do { try self.persist(report) } catch {
          self.logger.error("Evidence write failed: \(String(describing: error), privacy: .public)")
          throw SampleError.evidenceWriteFailed(
            "검증 실패: \(report.error ?? "unknown"); 기록 저장 실패: \(error)")
        }
        throw error
      }
    }
  }

  /// The hosted test waits for the same operation driven by the visible app.
  func waitUntilIdle() async {
    await operation?.value
  }

  private func begin(_ work: @escaping @MainActor () async throws -> Void) {
    guard operation == nil else { return }
    let id = UUID()
    operationID = id
    errorMessage = nil
    progress = nil
    isStopping = false
    operation = Task { [self] in
      do {
        try await work()
      } catch {
        if Self.isCancellation(error) {
          status = "중지됨"
        } else {
          errorMessage = String(describing: error)
          status = "실패 · 다시 실행할 수 있습니다."
        }
      }
      // Work has settled before clearing the profile and native residency.
      // Cleanup gets an uncancelled task because unload rejects cancellation.
      if releaseAfterStop {
        do {
          try await Task { @MainActor in try await self.unload() }.value
          status = "메모리 해제 완료 · 다운로드 파일은 보관됩니다."
        } catch {
          errorMessage = "메모리 해제 실패: \(error)"
          status = "메모리 해제 실패"
        }
      }
      guard operationID == id else { return }
      releaseAfterStop = false
      isStopping = false
      progress = nil
      operationID = nil
      operation = nil
    }
  }

  private func currentID() throws -> UUID {
    guard let operationID else { throw SampleError.missingOperation }
    return operationID
  }

  private func loadSession(id: UUID) async throws -> AppleLocalAISession {
    if let session, isLoaded, session.activeModel != nil { return session }
    let runtime: AppleLocalAILEAPRuntime
    if let existing = self.runtime {
      runtime = existing
    } else {
      let root = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      ).appending(path: "OnDemandModels", directoryHint: .isDirectory)
      runtime = try AppleLocalAILEAPRuntime(rootURL: root)
      self.runtime = runtime
    }
    status = "모델 확인·다운로드 중"
    preparing = true
    let prepared: AppleLocalAILEAPPreparedTextModel
    do {
      prepared = try await runtime.prepareTextModel { [weak self] update in
        Task { @MainActor in
          guard let self, self.operationID == id, self.preparing, !self.isStopping else { return }
          self.progress = update.fractionCompleted
          self.status =
            switch update.phase {
            case .checking: "모델 파일 확인 중"
            case .downloading: "모델 다운로드 중"
            case .verifying: "모델 무결성 확인 중"
            case .ready: "모델 준비 완료"
            }
        }
      }
    } catch {
      preparing = false
      throw error
    }
    preparing = false
    progress = nil
    try Task.checkCancellation()
    status = "모델 로드 중"
    let model = try await runtime.makeTextModel(from: prepared)
    isLoaded = true
    let profile = try AppleLocalAIProfile(
      model: model, instructions: "Answer briefly.", maximumResponseTokens: 128,
      transcriptErrorHandlingPolicy: .preserveTranscript)
    if let session {
      // This sample starts a fresh conversation after releasing residency.
      try session.reset(profile: profile)
      return session
    }
    let session = AppleLocalAISession(profile: profile)
    self.session = session
    return session
  }

  private func unload() async throws {
    try session?.clearProfile()
    if let runtime { try await runtime.unload() }
    isLoaded = false
  }

  private func verify(into report: inout VerificationEvidence) async throws {
    let id = try currentID()
    let session = try await loadSession(id: id)
    report.checks.append(.init(name: "verified-download-and-load", details: report.modelSHA256))
    try persist(report)
    status = "검증: 실제 응답"
    let response = try await session.respond(
      AppleLocalAIRequest(text: "Say hello in one short sentence."))
    try Self.requireReadable(response.content)
    result = response.content
    report.checks.append(.init(name: "respond", details: response.content))
    try persist(report)

    status = "검증: 스트리밍"
    var snapshots = 0
    let stream = try await session.stream(AppleLocalAIRequest(text: "Name one common fruit.")) {
      snapshot in
      guard self.operationID == id, !self.isStopping else { return }
      snapshots += 1
      self.result = snapshot.text
    }
    try Self.requireReadable(stream.text)
    guard snapshots > 0 else { throw SampleError.noSnapshots }
    report.checks.append(.init(name: "stream", details: "\(snapshots) snapshots; \(stream.text)"))
    try persist(report)

    status = "검증: 스트리밍 취소"
    var requestedCancellation = false
    var cancellationTrigger = ""
    let cancellationWatcher = Task { @MainActor in
      while session.phase == .idle {
        guard !Task.isCancelled else { return }
        await Task.yield()
      }
      guard session.phase == .running else { return }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      guard !Task.isCancelled, session.phase == .running, !requestedCancellation else { return }
      requestedCancellation = true
      cancellationTrigger = "150 ms timer while generation running"
      session.cancel()
    }
    var cancellationError: (any Error)?
    do {
      _ = try await session.stream(
        AppleLocalAIRequest(text: "List twenty common fruits with a short description of each.")
      ) { snapshot in
        if !snapshot.text.isEmpty, !requestedCancellation {
          requestedCancellation = true
          cancellationTrigger = "After a real snapshot"
          session.cancel()
        }
      }
    } catch {
      cancellationError = error
    }
    cancellationWatcher.cancel()
    await cancellationWatcher.value
    guard let cancellationError else { throw SampleError.cancellationNotObserved }
    guard case .some(.cancelled) = cancellationError as? AppleLocalAIError else {
      throw cancellationError
    }
    guard requestedCancellation, session.phase == .idle else {
      throw SampleError.cancellationNotSettled
    }
    report.checks.append(
      .init(
        name: "cancel-and-settle",
        details: "\(cancellationTrigger); cancellation observed; session idle"))
    try persist(report)

    let reused = try await session.respond(AppleLocalAIRequest(text: "Name one common color."))
    try Self.requireReadable(reused.content)
    report.checks.append(.init(name: "reuse-after-cancel", details: reused.content))
    try persist(report)

    status = "검증: 메모리 해제"
    guard let runtime else { throw SampleError.missingRuntime }
    let prepared = try await runtime.prepareTextModel()
    let attributes = try FileManager.default.attributesOfItem(atPath: prepared.localURL.path)
    guard let modified = attributes[.modificationDate] as? Date else {
      throw SampleError.cacheChanged
    }
    try await unload()
    guard session.activeModel == nil, !isLoaded else { throw SampleError.unloadNotConfirmed }
    do {
      try await runtime.prewarmTextModel()
      throw SampleError.unloadNotConfirmed
    } catch AppleLocalAILEAPError.modelNotPrepared {}
    report.checks.append(
      .init(name: "unload", details: "Profile cleared; unloaded runtime rejects prewarm"))
    try persist(report)

    status = "검증: 캐시 모델 다시 로드"
    let reloaded = try await loadSession(id: id)
    let cachedAttributes = try FileManager.default.attributesOfItem(atPath: prepared.localURL.path)
    guard modified == cachedAttributes[.modificationDate] as? Date,
      cachedAttributes[.size] as? UInt64 == AppleLocalAILEAPTextModel.default.byteCount
    else { throw SampleError.cacheChanged }
    let afterReload = try await reloaded.respond(
      AppleLocalAIRequest(text: "Say goodbye in one short sentence."))
    try Self.requireReadable(afterReload.content)
    result = afterReload.content
    report.checks.append(.init(name: "cache-reload-and-respond", details: afterReload.content))
    try persist(report)
    try await unload()
    report.checks.append(.init(name: "final-unload", details: "Model file retained"))
    try persist(report)
  }

  nonisolated static func requireReadable(_ text: String) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.contains(where: { $0.isLetter }),
      !trimmed.contains("<|"), !trimmed.contains("[INST]"), !trimmed.contains("</s>")
    else { throw SampleError.invalidResponse(text) }
  }

  nonisolated private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case .some(.cancelled) = error as? AppleLocalAIError { return true }
    return false
  }

  private func persist(_ report: VerificationEvidence) throws {
    let documents = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(
      to: documents.appending(path: "on-demand-verification.json"), options: .atomic)
    evidence = report
    logger.notice(
      "On-demand verification \(report.outcome, privacy: .public), \(report.checks.count) checks")
  }
}

struct VerificationEvidence: Encodable, Sendable {
  struct Check: Encodable, Sendable {
    let name: String
    let details: String
  }
  var outcome = "RUNNING"
  let runID = UUID()
  let model = AppleLocalAILEAPTextModel.default.modelID
  let modelRevision = AppleLocalAILEAPTextModel.default.revision
  let modelSHA256 = AppleLocalAILEAPTextModel.default.sha256
  let nativeSDK = AppleLocalAILEAP.leapSDKVersion
  let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  let startedAt = Date()
  var checks: [Check] = []
  var error: String?
}

enum SampleError: Error {
  case missingOperation
  case missingRuntime
  case invalidResponse(String)
  case noSnapshots
  case cancellationNotObserved
  case cancellationNotSettled
  case unloadNotConfirmed
  case cacheChanged
  case evidenceWriteFailed(String)
}
