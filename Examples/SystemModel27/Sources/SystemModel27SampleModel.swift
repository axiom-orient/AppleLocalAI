import AppleLocalAI
import Foundation
import FoundationModels
import OSLog
import Observation

/// The UI owns one operation; AppleLocalAISession owns SDK admission/cancellation
/// and Apple's native session remains the conversation authority.
@MainActor
@Observable
final class SystemModel27SampleModel {
  var prompt = "Say hello in one short sentence."
  private(set) var status = "Apple 모델 상태를 확인합니다."
  private(set) var result = ""
  private(set) var errorMessage: String?
  private(set) var isStopping = false
  private(set) var report: SystemModel27Report?
  var isWorking: Bool { operation != nil }
  var isSessionBusy: Bool { session?.isBusy == true }
  var canRun: Bool {
    model.availability == .available && !isWorking && !isSessionBusy
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var availabilityMessage: String {
    switch model.availability {
    case .available: "사용 가능"
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible: "사용 불가 · Apple Intelligence 지원 기기가 아닙니다."
      case .appleIntelligenceNotEnabled: "사용 불가 · Apple Intelligence가 꺼져 있습니다."
      case .modelNotReady: "사용 불가 · 시스템 모델 준비 중입니다."
      @unknown default: "사용 불가 · \(reason)"
      }
    }
  }

  @ObservationIgnored private let model = SystemLanguageModel.default
  @ObservationIgnored private var session: AppleLocalAISession?
  private var operation: Task<Void, Never>?
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.applelocalai.systemmodel27", category: "verification")

  func run() {
    guard canRun else { return }
    let text = prompt
    result = ""
    begin {
      try self.requireReady()
      let session: AppleLocalAISession
      if let existing = self.session {
        session = existing
      } else {
        session = AppleLocalAISession(profile: try self.makeProfile())
        self.session = session
      }
      self.status = "응답 생성 중"
      let response = try await session.stream(AppleLocalAIRequest(text: text)) { snapshot in
        guard !self.isStopping else { return }
        self.result = snapshot.text
      }
      try Task.checkCancellation()
      try Self.requireReadable(response.text)
      self.result = response.text
      self.status = "완료"
    }
  }

  func stop() {
    guard operation != nil else { return }
    isStopping = true
    status = "중지 처리 중"
    session?.cancel()
    operation?.cancel()
  }

  func startVerification() {
    guard operation == nil, !isSessionBusy else { return }
    report = nil
    result = ""
    begin {
      var report = SystemModel27Report(
        availabilityBefore: String(describing: self.model.availability))
      do {
        try self.persist(report)
        do { try self.requireReady() } catch SystemModel27Error.unavailable(let reason) {
          report.outcome = "UNAVAILABLE"
          report.unavailableReason = String(describing: reason)
          report.availabilityAtOutcome = String(describing: self.model.availability)
          try self.persist(report)
          self.status = "사용 불가 확인 · 추론은 실행하지 않았습니다."
          return
        }
        let profile = try self.makeProfile()
        let session = AppleLocalAISession(profile: profile)
        self.session = session
        try await self.qualify(session, profile: profile, report: &report)
        report.outcome = "INFERENCE_PASS"
        report.availabilityAtOutcome = String(describing: self.model.availability)
        try self.persist(report)
        self.status = "AppleLocalAI 실제 시스템 모델 검증 완료"
      } catch {
        report.outcome = "FAIL"
        report.error = String(describing: error)
        report.availabilityAtOutcome = String(describing: self.model.availability)
        self.report = report
        do { try self.persist(report) } catch {
          throw SystemModel27Error.evidenceWriteFailed(
            "검증 실패: \(report.error ?? "unknown"); 기록 저장 실패: \(error)")
        }
        throw error
      }
    }
  }

  func waitUntilIdle() async {
    await operation?.value
  }

  private func qualify(
    _ session: AppleLocalAISession, profile: AppleLocalAIProfile,
    report: inout SystemModel27Report
  ) async throws {
    try requireReadyAndIdle(session)
    status = "검증: 응답"
    let response = try await session.respond(
      AppleLocalAIRequest(text: "Say hello in one short sentence."))
    try Self.requireReadable(response.content)
    guard response.usage.output.totalTokenCount > 0, session.phase == .idle,
      Self.lastResponse(in: session.history) == response.content
    else {
      throw SystemModel27Error.inconsistentResponse
    }
    let firstHistory = session.history
    result = response.content
    try record("respond", response.content, in: &report)

    try requireReadyAndIdle(session)
    status = "검증: 스트리밍"
    var snapshots = 0
    var latestText = ""
    let stream = try await session.stream(
      AppleLocalAIRequest(text: "Name one common fruit in a short sentence.")
    ) { snapshot in
      snapshots += 1
      latestText = snapshot.text
      self.result = snapshot.text
    }
    try Self.requireReadable(stream.text)
    guard snapshots > 0, latestText == stream.text, stream.usage.output.totalTokenCount > 0,
      Self.lastResponse(in: session.history) == stream.text,
      Array(session.history.prefix(firstHistory.count)) == firstHistory,
      Array(session.history.suffix(stream.transcriptEntries.count)) == stream.transcriptEntries
    else { throw SystemModel27Error.inconsistentStream }
    report.streamSnapshotCount = snapshots
    try record(
      "stream", "\(snapshots) native snapshots; final response/history consistent; \(stream.text)",
      in: &report)

    try requireReadyAndIdle(session)
    status = "검증: 실행 중 취소"
    let generation = Task { @MainActor in
      try await session.stream(
        AppleLocalAIRequest(
          text: "Explain photosynthesis in twenty numbered paragraphs with detailed examples."),
        options: GenerationOptions(maximumResponseTokens: 2_048)
      ) { _ in }
    }
    var cancelledWhileRunning = false
    let watcher = Task { @MainActor in
      while session.phase == .idle {
        guard !Task.isCancelled else { return }
        await Task.yield()
      }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      guard !Task.isCancelled, session.phase == .running else { return }
      cancelledWhileRunning = true
      session.cancel()
    }
    let terminal = await withTaskCancellationHandler {
      await generation.result
    } onCancel: {
      generation.cancel()
    }
    watcher.cancel()
    await watcher.value
    try Task.checkCancellation()
    guard cancelledWhileRunning else { throw SystemModel27Error.cancellationNotObserved }
    switch terminal {
    case .success: throw SystemModel27Error.cancellationNotObserved
    case .failure(let error):
      guard case .some(.cancelled) = error as? AppleLocalAIError else { throw error }
    }
    guard session.phase == .idle, !session.isBusy else { throw SystemModel27Error.sessionBusy }
    try record(
      "cancel-and-settle",
      "Cancelled 150 ms after SDK running; cancellation observed; idle after task settlement",
      in: &report)

    try requireReadyAndIdle(session)
    status = "검증: 같은 세션 재사용"
    let reused = try await session.respond(
      AppleLocalAIRequest(text: "Name one common color in a short sentence."))
    try Self.requireReadable(reused.content)
    guard session.phase == .idle, Self.lastResponse(in: session.history) == reused.content else {
      throw SystemModel27Error.inconsistentResponse
    }
    result = reused.content
    report.response = reused.content
    try record("reuse-after-cancel", reused.content, in: &report)

    try requireReadyAndIdle(session)
    status = "검증: 구조화 응답"
    let generated = try await session.generate(
      AppleLocalAIRequest(text: "Put the name of one common fruit in the answer field."),
      generating: SystemModel27Answer.self)
    try Self.requireReadable(generated.content.answer)
    guard generated.usage.output.totalTokenCount > 0 else {
      throw SystemModel27Error.inconsistentResponse
    }
    try record("structured-generation", generated.content.answer, in: &report)

    try requireReadyAndIdle(session)
    status = "검증: profile·대화 초기화"
    let history = session.history
    try session.reconfigure(
      AppleLocalAIProfile(
        model: model, instructions: "Give one short sentence.", maximumResponseTokens: 96,
        transcriptErrorHandlingPolicy: .preserveTranscript))
    let reconfigured = try await session.respond(AppleLocalAIRequest(text: "Say goodbye."))
    try Self.requireReadable(reconfigured.content)
    guard Array(session.history.prefix(history.count)) == history else {
      throw SystemModel27Error.historyChanged
    }
    let completedHistory = session.history
    try session.clearProfile()
    guard session.activeModel == nil, session.history == completedHistory else {
      throw SystemModel27Error.historyChanged
    }
    try session.reset(profile: profile)
    guard session.history.isEmpty else { throw SystemModel27Error.historyChanged }
    try requireReadyAndIdle(session)
    try record(
      "profile-and-reset",
      "Native history preserved across profile changes; explicit reset starts a new conversation",
      in: &report)
  }

  private func makeProfile() throws -> AppleLocalAIProfile {
    try AppleLocalAIProfile(
      model: model, instructions: "Answer briefly.", maximumResponseTokens: 96,
      transcriptErrorHandlingPolicy: .preserveTranscript)
  }

  private func requireReady() throws {
    try Task.checkCancellation()
    if case .unavailable(let reason) = model.availability {
      throw SystemModel27Error.unavailable(reason)
    }
    // Native availability admits requests. Supplemental context-size metadata
    // can be zero in Simulator even when actual native inference succeeds.
  }

  private func requireReadyAndIdle(_ session: AppleLocalAISession) throws {
    try requireReady()
    guard self.session === session else { throw SystemModel27Error.sessionChanged }
    guard session.phase == .idle, !session.isBusy else { throw SystemModel27Error.sessionBusy }
  }

  private func begin(_ work: @escaping @MainActor () async throws -> Void) {
    guard operation == nil, !isSessionBusy else { return }
    errorMessage = nil
    isStopping = false
    operation = Task { [self] in
      do { try await work() } catch {
        if error is CancellationError || Task.isCancelled {
          status = "중지됨"
        } else {
          errorMessage = String(describing: error)
          status = "실패"
        }
      }
      isStopping = false
      operation = nil
    }
  }

  private func record(_ name: String, _ details: String, in report: inout SystemModel27Report)
    throws
  {
    report.checks.append(.init(name: name, details: details))
    try persist(report)
  }

  private func persist(_ report: SystemModel27Report) throws {
    let documents = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(
      to: documents.appending(path: "system-model27-verification.json"), options: .atomic)
    self.report = report
    logger.notice("System model 27 verification \(report.outcome, privacy: .public)")
  }

  private static func lastResponse(in history: [Transcript.Entry]) -> String? {
    for entry in history.reversed() {
      if case .response(let response) = entry {
        return response.segments.compactMap { segment in
          if case .text(let text) = segment { text.content } else { nil }
        }.joined()
      }
    }
    return nil
  }

  private static func requireReadable(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.contains(where: { $0.isLetter }), !text.contains("<|")
    else { throw SystemModel27Error.invalidResponse }
  }
}

@Generable
private struct SystemModel27Answer {
  let answer: String
}

struct SystemModel27Report: Encodable, Sendable {
  struct Check: Encodable, Sendable {
    let name: String
    let details: String
  }
  let runID = UUID()
  let startedAt = Date()
  let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  let provider = "Root AppleLocalAISession / Apple SystemLanguageModel.default"
  let transcriptPolicy = "preserveTranscript; SDK default remains revertTranscript"
  let availabilityBefore: String
  var availabilityAtOutcome: String?
  var outcome = "RUNNING"
  var checks: [Check] = []
  var streamSnapshotCount: Int?
  var unavailableReason: String?
  var response: String?
  var error: String?
}

enum SystemModel27Error: Error {
  case unavailable(SystemLanguageModel.Availability.UnavailableReason)
  case invalidResponse
  case inconsistentResponse
  case inconsistentStream
  case cancellationNotObserved
  case sessionBusy
  case sessionChanged
  case historyChanged
  case evidenceWriteFailed(String)
}
