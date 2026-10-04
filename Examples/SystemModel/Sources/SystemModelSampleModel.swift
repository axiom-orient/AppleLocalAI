import AppleLocalAISystem
import Foundation
import FoundationModels
import OSLog
import Observation

/// UI work has one task owner. Apple's session owns conversation and inference.
@MainActor
@Observable
final class SystemModelSampleModel {
  var prompt = "Say hello in one short sentence."
  var availabilityMessage: String {
    Self.message(for: model.availability)
  }
  var environmentIssue: String? { environment.issue }
  var isAvailable: Bool { model.availability == .available }
  private(set) var status = "Apple 모델 상태를 확인합니다."
  private(set) var result = ""
  private(set) var errorMessage: String?
  private(set) var errorDetails: String?
  private(set) var isStopping = false
  private(set) var report: SystemModelVerificationReport?
  var isWorking: Bool { operation != nil }
  var isNativeResponding: Bool { session?.isResponding == true }
  var canRun: Bool {
    isAvailable && !isWorking && session?.isResponding != true
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ObservationIgnored private let model = SystemLanguageModel.default
  @ObservationIgnored private let environment = SystemModelExecutionEnvironment.current
  @ObservationIgnored private var session: LanguageModelSession?
  private var operation: Task<Void, Never>?
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.applelocalai.systemmodel", category: "verification")

  func run() {
    guard canRun else { return }
    let text = prompt
    result = ""
    begin {
      let session = try self.admitSession()
      self.status = "응답 생성 중"
      let response = try await session.respond(
        to: text, options: GenerationOptions(maximumResponseTokens: 64))
      try Task.checkCancellation()
      try Self.requireReadable(response.content)
      self.result = response.content
      self.status = "완료"
    }
  }

  func stop() {
    guard operation != nil else { return }
    isStopping = true
    status = "중지 처리 중"
    operation?.cancel()
  }

  func startVerification() {
    guard operation == nil, session?.isResponding != true else { return }
    report = nil
    begin {
      var report = SystemModelVerificationReport(
        availabilityBefore: Self.code(for: self.model.availability),
        isSimulator: self.environment.isSimulator, runtimeVersion: self.environment.runtimeVersion,
        simulatorHostVersion: self.environment.hostVersion)
      do {
        try self.persist(report)
        let nativeSession: LanguageModelSession
        do {
          nativeSession = try AppleLocalAISystem.makeSession(
            model: self.model, instructions: Instructions("Answer briefly."))
        } catch AppleLocalAISystemError.unavailable(let reason) {
          report.admission = "REJECTED_UNAVAILABLE"
          report.unavailableReason = String(describing: reason)
          report.availabilityAtOutcome = Self.code(for: self.model.availability)
          report.outcome = "UNAVAILABLE"
          try self.persist(report)
          self.status = "사용 불가 확인 · 실제 추론은 실행하지 않았습니다."
          return
        }
        report.admission = "ACCEPTED"
        self.session = nativeSession
        try self.record(
          "admission", "Native session accepted; isResponding=\(nativeSession.isResponding)",
          in: &report)
        try await self.qualify(nativeSession, report: &report)
        report.availabilityAtOutcome = Self.code(for: self.model.availability)
        report.outcome = "INFERENCE_PASS"
        try self.persist(report)
        self.status = "실제 Apple 모델 추론 확인 완료"
      } catch {
        report.outcome = "FAIL"
        report.error = String(describing: error)
        report.availabilityAtOutcome = Self.code(for: self.model.availability)
        self.report = report
        do { try self.persist(report) } catch {
          throw SystemModelSampleError.evidenceWriteFailed(
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
    _ session: LanguageModelSession, report: inout SystemModelVerificationReport
  ) async throws {
    try requireAvailableAndIdle(session)
    status = "검증: 실제 Apple 모델 응답"
    let response = try await session.respond(
      to: "Say hello in one short sentence.",
      options: GenerationOptions(maximumResponseTokens: 64))
    try Task.checkCancellation()
    try Self.requireReadable(response.content)
    try await waitForNativeIdle(session)
    result = response.content
    report.response = response.content
    try record("respond", response.content, in: &report)
    let firstTranscript = try Self.inspectTranscript(
      session, expectedResponse: response.content, minimumCompletedTurns: 1)
    try record("transcript-after-respond", firstTranscript, in: &report)

    try requireAvailableAndIdle(session)
    status = "검증: 실제 스트리밍"
    var snapshots = 0
    var streamedText = ""
    for try await snapshot in session.streamResponse(
      to: "Name one common fruit in one short sentence.",
      options: GenerationOptions(maximumResponseTokens: 64))
    {
      try Task.checkCancellation()
      snapshots += 1
      streamedText = snapshot.content
      result = streamedText
    }
    try Task.checkCancellation()
    try Self.requireReadable(streamedText)
    guard snapshots > 0 else { throw SystemModelSampleError.noStreamSnapshots }
    try await waitForNativeIdle(session)
    let streamTranscript = try Self.inspectTranscript(
      session, expectedResponse: streamedText, minimumCompletedTurns: 2)
    report.streamSnapshotCount = snapshots
    report.streamResponse = streamedText
    try record(
      "stream", "\(snapshots) snapshots; final matches native transcript; \(streamTranscript)",
      in: &report)

    try requireAvailableAndIdle(session)
    status = "검증: 실행 중 취소"
    let generation = Task { @MainActor in
      let response = try await session.respond(
        to: "Write a detailed explanation of photosynthesis in twenty numbered paragraphs.",
        options: GenerationOptions(maximumResponseTokens: 2_048))
      return response.content
    }
    var cancelledWhileNativeBusy = false
    let watcher = Task { @MainActor in
      while !session.isResponding {
        guard !Task.isCancelled else { return }
        await Task.yield()
      }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      guard !Task.isCancelled, session.isResponding else { return }
      cancelledWhileNativeBusy = true
      generation.cancel()
    }
    let terminal = await withTaskCancellationHandler {
      await generation.result
    } onCancel: {
      generation.cancel()
    }
    watcher.cancel()
    await watcher.value
    try Task.checkCancellation()
    guard cancelledWhileNativeBusy, generation.isCancelled else {
      throw SystemModelSampleError.cancellationNotObserved
    }
    switch terminal {
    case .success:
      throw SystemModelSampleError.cancellationNotObserved
    case .failure(let error):
      guard error is CancellationError else { throw error }
      report.cancellationError = String(describing: error)
    }
    try await waitForNativeIdle(session)
    report.nativeRespondingAtCancellation = cancelledWhileNativeBusy
    report.nativeRespondingAfterCancellation = session.isResponding
    try record(
      "cancel-and-settle",
      "Task cancelled 150 ms after native isResponding; native busy at cancel=true; after native task settled=false",
      in: &report)

    try requireAvailableAndIdle(session)
    status = "검증: 취소 후 같은 세션 재사용"
    let reused = try await session.respond(
      to: "Name one common color in one short sentence.",
      options: GenerationOptions(maximumResponseTokens: 64))
    try Task.checkCancellation()
    try Self.requireReadable(reused.content)
    try await waitForNativeIdle(session)
    result = reused.content
    report.response = reused.content
    try record("reuse-after-cancel", reused.content, in: &report)
    let finalTranscript = try Self.inspectTranscript(
      session, expectedResponse: reused.content, minimumCompletedTurns: 3)
    try record("native-transcript", finalTranscript, in: &report)
    try requireAvailableAndIdle(session)
  }

  private func requireAvailableAndIdle(_ session: LanguageModelSession) throws {
    try Task.checkCancellation()
    if case .unavailable(let reason) = model.availability {
      throw AppleLocalAISystemError.unavailable(reason)
    }
    guard self.session === session else { throw SystemModelSampleError.sessionIdentityChanged }
    guard !session.isResponding else { throw SystemModelSampleError.nativeStillResponding }
  }

  private func waitForNativeIdle(_ session: LanguageModelSession) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while session.isResponding {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw SystemModelSampleError.nativeStillResponding
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Read-only evidence from Apple's transcript, not another conversation ledger.
  nonisolated private static func inspectTranscript(
    _ session: LanguageModelSession, expectedResponse: String, minimumCompletedTurns: Int
  ) throws -> String {
    let transcript = session.transcript
    var instructions = 0
    var prompts = 0
    var responses = 0
    var latestResponse = ""
    for entry in transcript {
      switch entry {
      case .instructions: instructions += 1
      case .prompt: prompts += 1
      case .response(let response):
        responses += 1
        latestResponse = response.segments.compactMap { segment in
          if case .text(let text) = segment { text.content } else { nil }
        }.joined()
      default: break
      }
    }
    guard instructions > 0, prompts >= minimumCompletedTurns,
      responses >= minimumCompletedTurns, latestResponse == expectedResponse,
      Set(transcript.map(\.id)).count == transcript.count
    else { throw SystemModelSampleError.transcriptMismatch }
    return
      "\(transcript.count) entries; \(instructions) instructions; \(prompts) prompts; \(responses) responses; unique IDs; last response matches"
  }

  private func admitSession() throws -> LanguageModelSession {
    // Check the live native availability even when borrowing the existing session.
    if case .unavailable(let reason) = model.availability {
      throw AppleLocalAISystemError.unavailable(reason)
    }
    if let session { return session }
    let session = try AppleLocalAISystem.makeSession(
      model: model, instructions: Instructions("Answer briefly."))
    self.session = session
    return session
  }

  private func begin(_ work: @escaping @MainActor () async throws -> Void) {
    guard operation == nil, session?.isResponding != true else { return }
    errorMessage = nil
    errorDetails = nil
    isStopping = false
    operation = Task { [self] in
      do { try await work() } catch {
        if error is CancellationError || Task.isCancelled {
          status = "중지됨"
        } else {
          errorDetails = String(describing: error)
          errorMessage = Self.readableFailure(error, isSimulator: environment.isSimulator)
          logger.error("Native generation failed: \(String(describing: error), privacy: .private)")
          status = "실패"
        }
      }
      // Retain the task until respond returns; admission also checks isResponding.
      isStopping = false
      operation = nil
    }
  }

  private func persist(_ report: SystemModelVerificationReport) throws {
    let documents = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(
      to: documents.appending(path: "system-model-verification.json"), options: .atomic)
    self.report = report
    logger.notice("System model verification \(report.outcome, privacy: .public)")
  }

  private func record(
    _ name: String, _ details: String, in report: inout SystemModelVerificationReport
  ) throws {
    report.checks.append(.init(name: name, details: details))
    try persist(report)
  }

  nonisolated static func code(for availability: SystemLanguageModel.Availability) -> String {
    switch availability {
    case .available: "available"
    case .unavailable(let reason): "unavailable:\(reason)"
    }
  }

  nonisolated private static func message(for availability: SystemLanguageModel.Availability)
    -> String
  {
    switch availability {
    case .available:
      "사용 가능"
    case .unavailable(let reason):
      switch reason {
      case .deviceNotEligible: "사용 불가 · Apple Intelligence 지원 기기가 아닙니다."
      case .appleIntelligenceNotEnabled: "사용 불가 · 설정에서 Apple Intelligence를 켜세요."
      case .modelNotReady: "사용 불가 · 시스템 모델이 아직 준비되지 않았습니다."
      @unknown default: "사용 불가 · \(reason)"
      }
    }
  }

  nonisolated private static func requireReadable(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.contains(where: { $0.isLetter }), !text.contains("<|")
    else { throw SystemModelSampleError.invalidResponse }
  }

  nonisolated private static func readableFailure(_ error: any Error, isSimulator: Bool) -> String {
    if let unavailable = error as? AppleLocalAISystemError {
      return unavailable.localizedDescription
    }
    let details = String(describing: error)
    if details.contains("SensitiveContentAnalysisML") || details.contains("ModelManagerServices") {
      return isSimulator
        ? "Simulator의 Apple 시스템 모델 내부 오류로 추론에 실패했습니다. 오류 상세를 확인하세요."
        : "Apple 시스템 모델을 실행하지 못했습니다. 기기의 시스템 모델 준비 상태를 확인하세요."
    }
    return "응답 생성에 실패했습니다. Apple 모델의 준비 상태를 확인하세요."
  }
}

struct SystemModelVerificationReport: Encodable, Sendable {
  struct Check: Encodable, Sendable {
    let name: String
    let details: String
  }
  let runID = UUID()
  let startedAt = Date()
  let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  let provider = "Apple.SystemLanguageModel.default"
  let availabilityBefore: String
  let isSimulator: Bool
  let runtimeVersion: String
  let simulatorHostVersion: String?
  var availabilityAtOutcome: String?
  var admission = "NOT_ATTEMPTED"
  var outcome = "RUNNING"
  var unavailableReason: String?
  var response: String?
  var streamResponse: String?
  var streamSnapshotCount: Int?
  var nativeRespondingAtCancellation: Bool?
  var nativeRespondingAfterCancellation: Bool?
  var cancellationError: String?
  var checks: [Check] = []
  var error: String?
}

enum SystemModelSampleError: Error {
  case invalidResponse
  case noStreamSnapshots
  case cancellationNotObserved
  case nativeStillResponding
  case transcriptMismatch
  case sessionIdentityChanged
  case evidenceWriteFailed(String)
}
