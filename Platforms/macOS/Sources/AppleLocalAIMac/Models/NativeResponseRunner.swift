#if os(macOS)

  import AppleLocalAI
  import AppleLocalAIFoundationModels
  import Foundation
  import FoundationModels

  /// Executes one native response without owning the session or application state.
  /// The caller decides whether each snapshot still belongs to its live operation.
  @MainActor
  enum NativeResponseRunner {
    struct Snapshot {
      let answer: String
      let usage: LanguageModelSession.Usage
      let transcriptEntryCount: Int
    }

    static func run(
      session: AppleLocalAISession,
      request: AppleLocalAIRequest,
      mode: FoundationModelResponseMode,
      schema: GenerationSchema?,
      options: GenerationOptions,
      contextOptions: ContextOptions,
      metadata: [String: any ConvertibleToGeneratedContent],
      onSnapshot: @escaping @MainActor (Snapshot) -> Void
    ) async throws -> String {
      switch mode {
      case .text:
        let snapshot = try await session.stream(
          request,
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        ) { snapshot in
          onSnapshot(
            Snapshot(
              answer: snapshot.text,
              usage: snapshot.usage,
              transcriptEntryCount: snapshot.transcriptEntries.count
            ))
        }
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw AppleLocalAIModelError.emptyResponse
        }
        return snapshot.text

      case .typed:
        let snapshot = try await session.streamGenerated(
          request,
          generating: FoundationModelsStructuredResponse.self,
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        ) { snapshot in
          onSnapshot(
            Snapshot(
              answer: snapshot.rawContent.jsonString,
              usage: snapshot.usage,
              transcriptEntryCount: snapshot.transcriptEntries.count
            ))
        }
        return try structuredAnswer(snapshot.rawContent)

      case .dynamicSchema:
        guard let schema else {
          throw AppleLocalAIModelError.invalidGenerationSchema("dynamic schema is missing")
        }
        let snapshot = try await session.stream(
          request,
          schema: schema,
          options: options,
          contextOptions: contextOptions,
          metadata: metadata
        ) { snapshot in
          onSnapshot(
            Snapshot(
              answer: snapshot.content.jsonString,
              usage: snapshot.usage,
              transcriptEntryCount: snapshot.transcriptEntries.count
            ))
        }
        return try structuredAnswer(snapshot.content)
      }
    }

    private static func structuredAnswer(_ content: GeneratedContent) throws -> String {
      guard content.isComplete else {
        throw AppleLocalAIModelError.emptyResponse
      }
      let value: FoundationModelsStructuredResponse
      do {
        value = try FoundationModelsResponseSchema.decode(content)
      } catch {
        throw AppleLocalAIModelError.invalidGenerationSchema(error.localizedDescription)
      }
      var sections = [value.summary]
      if !value.keyPoints.isEmpty {
        sections.append("핵심\n" + value.keyPoints.map { "• \($0)" }.joined(separator: "\n"))
      }
      if !value.nextActions.isEmpty {
        sections.append("다음 단계\n" + value.nextActions.map { "• \($0)" }.joined(separator: "\n"))
      }
      return sections.joined(separator: "\n\n")
    }
  }

#endif
