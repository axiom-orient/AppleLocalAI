#if os(macOS)

  import Foundation
  import VisionKit

  enum VisionKitTextExtractionError: LocalizedError {
    case unsupported
    case noText

    var errorDescription: String? {
      switch self {
      case .unsupported:
        return "이 Mac에서는 이미지 텍스트 분석을 사용할 수 없습니다."
      case .noText:
        return "이미지에서 텍스트를 찾지 못했습니다."
      }
    }
  }

  /// Direct macOS image analysis for user-visible Live Text/OCR actions.
  /// Foundation Models remains responsible for semantic image requests.
  @MainActor
  struct VisionKitTextExtractor {
    private let resourceAccess: any SecurityScopedResourceAccess

    init(
      resourceAccess: any SecurityScopedResourceAccess = SystemSecurityScopedResourceAccess()
    ) {
      self.resourceAccess = resourceAccess
    }

    func extractText(from url: URL) async throws -> String {
      try Task.checkCancellation()
      guard ImageAnalyzer.isSupported else {
        throw VisionKitTextExtractionError.unsupported
      }

      let transcript = try await SecurityScopedResource.withAccess(to: url, using: resourceAccess) {
        try await Self.analyzeText(at: url)
      }
      try Task.checkCancellation()
      let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        throw VisionKitTextExtractionError.noText
      }
      return text
    }

    // VisionKit's non-Sendable configuration stays inside the analysis task.
    // Only the file URL and resulting text cross the main-actor boundary.
    @concurrent
    nonisolated private static func analyzeText(at url: URL) async throws -> String {
      try Task.checkCancellation()
      let analyzer = ImageAnalyzer()
      let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
      return try await analyzer.analyze(
        imageAt: url, orientation: .up, configuration: configuration
      ).transcript
    }
  }

#endif
