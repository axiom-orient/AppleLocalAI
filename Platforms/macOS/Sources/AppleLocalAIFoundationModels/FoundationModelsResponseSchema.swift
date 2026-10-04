#if os(macOS)

  import Foundation
  import FoundationModels

  /// The one structured response contract shared by every Foundation Models
  /// backend. Providers receive this contract through Foundation Models' own
  /// `GenerationSchema`; they do not define a second provider-specific schema.
  public struct FoundationModelsStructuredResponse: Generable, Equatable, Sendable {
    public var summary: String
    public var keyPoints: [String]
    public var nextActions: [String]

    public init(
      summary: String,
      keyPoints: [String],
      nextActions: [String]
    ) {
      self.summary = summary
      self.keyPoints = keyPoints
      self.nextActions = nextActions
    }

    public static var generationSchema: GenerationSchema {
      FoundationModelsResponseSchema.typed()
    }

    public init(_ content: GeneratedContent) throws {
      summary = try content.value(
        String.self,
        forProperty: FoundationModelsResponseSchema.summaryKey
      )
      keyPoints = try content.value(
        [String].self,
        forProperty: FoundationModelsResponseSchema.keyPointsKey
      )
      nextActions = try content.value(
        [String].self,
        forProperty: FoundationModelsResponseSchema.nextActionsKey
      )
    }

    public var generatedContent: GeneratedContent {
      GeneratedContent(
        properties: [
          FoundationModelsResponseSchema.summaryKey: summary,
          FoundationModelsResponseSchema.keyPointsKey: keyPoints,
          FoundationModelsResponseSchema.nextActionsKey: nextActions,
        ]
      )
    }
  }

  /// Owns the response schema's names, descriptions, and bounds. Both typed
  /// and dynamic Foundation Models requests are projections of this contract.
  public enum FoundationModelsResponseSchema {
    public static let summaryKey = "summary"
    public static let keyPointsKey = "keyPoints"
    public static let nextActionsKey = "nextActions"
    public static let maximumListCount = 5

    private static let summaryDescription = "A concise answer in a few sentences."
    private static let keyPointsDescription = "The most important points."
    private static let nextActionsDescription = "Concrete next actions."

    public static func typed() -> GenerationSchema {
      GenerationSchema(
        type: FoundationModelsStructuredResponse.self,
        description: "A concise answer with important points and optional next actions.",
        properties: [
          .init(
            name: summaryKey,
            description: summaryDescription,
            type: String.self
          ),
          .init(
            name: keyPointsKey,
            description: keyPointsDescription,
            type: [String].self,
            guides: [.maximumCount(maximumListCount)]
          ),
          .init(
            name: nextActionsKey,
            description: nextActionsDescription,
            type: [String].self,
            guides: [.maximumCount(maximumListCount)]
          ),
        ]
      )
    }

    public static func dynamic() throws -> GenerationSchema {
      let string = DynamicGenerationSchema(type: String.self)
      let boundedStrings = DynamicGenerationSchema(
        arrayOf: string,
        maximumElements: maximumListCount
      )
      let root = DynamicGenerationSchema(
        name: "foundation_models_answer",
        description: "A concise answer with important points and optional next actions.",
        properties: [
          .init(
            name: summaryKey,
            description: summaryDescription,
            schema: string
          ),
          .init(
            name: keyPointsKey,
            description: keyPointsDescription,
            schema: boundedStrings
          ),
          .init(
            name: nextActionsKey,
            description: nextActionsDescription,
            schema: boundedStrings
          ),
        ]
      )
      return try GenerationSchema(root: root, dependencies: [])
    }

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
      case incomplete
      case invalidContent

      public var errorDescription: String? {
        switch self {
        case .incomplete:
          return "The structured response was incomplete."
        case .invalidContent:
          return "The structured response contained empty or excessive values."
        }
      }
    }

    public static func decode(
      _ content: GeneratedContent
    ) throws -> FoundationModelsStructuredResponse {
      guard content.isComplete else { throw ValidationError.incomplete }
      let value = try FoundationModelsStructuredResponse(content)
      guard let summary = normalizedText(value.summary),
        let keyPoints = normalizedList(value.keyPoints),
        let nextActions = normalizedList(value.nextActions)
      else { throw ValidationError.invalidContent }
      return FoundationModelsStructuredResponse(
        summary: summary,
        keyPoints: keyPoints,
        nextActions: nextActions
      )
    }

    private static func normalizedText(_ value: String) -> String? {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedList(_ values: [String]) -> [String]? {
      guard values.count <= maximumListCount else { return nil }
      let normalized = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      return normalized.allSatisfy { !$0.isEmpty } ? normalized : nil
    }
  }

#endif
