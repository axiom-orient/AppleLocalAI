import AppleLocalAI
import AppleLocalAIFoundationModels
import AppleLocalAIHost
import CoreAILanguageModels
import Evaluations
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAIMac

/// Small factual-preservation gate, not a general quality certification.
private struct NativeQualityEvaluation: Evaluation {
  let model: any LanguageModel
  init(model: any LanguageModel = SystemLanguageModel.default) { self.model = model }
  static let preservedFact = Metric("preserved_fact")
  let dataset = ArrayLoader(samples: [
    ModelSample(prompt: "메모: 회의는 화요일 오후 3시입니다. 회의 시간을 한 문장으로 알려줘.", expected: "3"),
    ModelSample(prompt: "메모: 주문 번호는 AB-204입니다. 주문 번호만 답하세요.", expected: "AB-204"),
    ModelSample(prompt: "The meeting room is Cedar. Return only the room name.", expected: "Cedar"),
    ModelSample(prompt: "자료: 총 12개 중 5개가 완료되었습니다. 완료한 개수만 답하세요.", expected: "5"),
    ModelSample(
      prompt: "The release code is LOCAL-73. Repeat the release code exactly.", expected: "LOCAL-73"
    ),
  ])

  func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
    try await Task { @MainActor in
      let session = AppleLocalAISession(
        profile: try AppleLocalAIProfile(
          model: model,
          instructions: LocalAIInstructions.system,
          samplingMode: .greedy
        )
      )
      let response = try await session.respond(
        AppleLocalAIRequest(prompt: sample.prompt),
        options: GenerationOptions(samplingMode: .greedy)
      )
      // Change the canonical profile and then recover the original fact from
      // the same native transcript owner.
      try session.reconfigure(
        try AppleLocalAIProfile(
          model: model,
          instructions: "Answer concisely using the facts in the conversation.",
          samplingMode: .greedy,
          historyPolicy: .recentEntries(8)
        )
      )
      let recalled = try await session.respond(
        try AppleLocalAIRequest(text: "Repeat your previous answer, preserving the exact fact.")
      )
      return ModelSubject(value: response.content + "\nPROFILE_RECALL\n" + recalled.content)
    }.value
  }

  var evaluators: Evaluators {
    Evaluator<ModelSample<String>> { sample, subject in
      guard let expected = sample.expected, !expected.isEmpty else {
        return Self.preservedFact.failing(rationale: "Missing reference")
      }
      let answers = subject.value.components(separatedBy: "\nPROFILE_RECALL\n")
      return answers.count == 2 && answers.allSatisfy { $0.contains(expected) }
        ? Self.preservedFact.passing() : Self.preservedFact.failing()
    }
  }

  func aggregateMetrics(using aggregator: inout MetricsAggregator) {
    aggregator.computeMean(of: Self.preservedFact)
  }
}

@Test(
  .timeLimit(.minutes(5)),
  .enabled(if: ProcessInfo.processInfo.environment["APPLELOCALAI_RUN_COREAI_EVALUATIONS"] == "1"))
func coreAIFactualPreservation() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["APPLELOCALAI_COREAI_MODEL_PATH"])
  let model = try await CoreAILanguageModel(resourcesAt: URL(fileURLWithPath: path))
  try await model.load()
  defer { model.unload() }
  let result = try await NativeQualityEvaluation(model: model).run(info: [
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "model": URL(fileURLWithPath: path).lastPathComponent,
    "scope": "Core AI production DynamicProfile factual preservation and history recall",
    "capabilities": FoundationModelCapability.allCases
      .filter { model.capabilities.contains($0.nativeValue) }.map(\.rawValue).sorted().joined(
        separator: ","),
  ])
  if let output = ProcessInfo.processInfo.environment["APPLELOCALAI_EVALUATION_OUTPUT"] {
    _ = try result.saveJSON(to: URL(fileURLWithPath: output, isDirectory: true))
  }
  #expect(!result.errors.hasFailures)
  #expect(result.errors.anyInferenceProduced)
  #expect(result.aggregateValue(.mean(of: NativeQualityEvaluation.preservedFact)) == 1)
}

@Test(
  .timeLimit(.minutes(2)),
  .enabled(if: ProcessInfo.processInfo.environment["APPLELOCALAI_RUN_EVALUATIONS"] == "1"))
func nativeFactualPreservation() async throws {
  let model = SystemLanguageModel.default
  try #require(model.availability == .available)
  try #require(model.supportsLocale(.current))
  let result = try await NativeQualityEvaluation().run(info: [
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "model": model.variant.displayName,
    "model_revision": "not exposed by SDK; OS build and runtime variant recorded",
    "capabilities": FoundationModelCapability.allCases
      .filter { model.capabilities.contains($0.nativeValue) }.map(\.rawValue).sorted().joined(
        separator: ","),
    "scope":
      "production DynamicProfile factual preservation and history recall; five samples, two turns each",
  ])
  if let output = ProcessInfo.processInfo.environment["APPLELOCALAI_EVALUATION_OUTPUT"] {
    _ = try result.saveJSON(to: URL(fileURLWithPath: output, isDirectory: true))
  }
  #expect(!result.errors.hasFailures)
  #expect(result.errors.anyInferenceProduced)
  #expect(result.aggregateValue(.mean(of: NativeQualityEvaluation.preservedFact)) == 1)
}
