import Foundation
@preconcurrency import LiteRTLM

public struct LiteRTModelCapabilities: Equatable, Hashable, Sendable {
  public let supportsText: Bool
  public let supportsVision: Bool
  public let supportsAudio: Bool
  public let supportsVideo: Bool
  public let supportsThinking: Bool
  public let supportsFunctionCalling: Bool
  public let maximumVisionTokenBudget: Int?
}

/// Pure preflight over the selected LiteRT-LM bundle metadata.
public enum LiteRTModelInspector {
  public static func capabilities(for modelURL: URL) -> LiteRTModelCapabilities? {
    let url = LocalModelAsset.canonicalURL(for: modelURL)
    guard LocalModelAsset.isReadableFile(at: url, extension: "litertlm"),
      LocalModelFileFormat.inspect(url) == .liteRT,
      let file = Capabilities(modelPath: url.path)
    else { return nil }

    let budget = file.maxVisionTokenBudget()
    return LiteRTModelCapabilities(
      supportsText: file.inputModalities.text,
      supportsVision: file.inputModalities.vision,
      supportsAudio: file.inputModalities.audio,
      supportsVideo: file.inputModalities.video,
      supportsThinking: file.supportsThinking(),
      supportsFunctionCalling: file.supportsFunctionCalling(),
      maximumVisionTokenBudget: budget >= 0 ? budget : nil
    )
  }
}
