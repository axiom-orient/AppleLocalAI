import CoreAILanguageModels
import Foundation

/// Storage/format admission only. Successful inference is a separate runtime fact.
public enum LocalModelAssetAdmission {
  public enum Kind: String, CaseIterable, Codable, Sendable {
    case mlx
    case liteRT
    case coreAI
  }

  public enum AdmissionError: Error, LocalizedError, Sendable {
    case invalidMLX
    case invalidLiteRT
    case missingEmbeddedTokenizer
    case escapingAssetPath(String)

    public var errorDescription: String? {
      switch self {
      case .invalidMLX:
        "A valid local MLX model/tokenizer directory is required."
      case .invalidLiteRT:
        "A readable .litertlm file with a LITERTLM header is required."
      case .missingEmbeddedTokenizer:
        "Core AI requires an embedded tokenizer.json. Implicit tokenizer downloads are disabled."
      case .escapingAssetPath(let value):
        "A Core AI asset must remain inside its imported bundle: \(value)"
      }
    }
  }

  public static func validate(_ url: URL, as kind: Kind) throws {
    switch kind {
    case .mlx:
      guard LocalModelAsset.isMLXModelDirectory(at: url) else {
        throw AdmissionError.invalidMLX
      }

    case .liteRT:
      guard LocalModelAsset.isReadableFile(at: url, extension: "litertlm"),
        LocalModelFileFormat.inspect(url) == .liteRT
      else { throw AdmissionError.invalidLiteRT }

    case .coreAI:
      let language = try LanguageModelBundle(at: url)
      try language.modelBundle.verifyAssetsExisting()
      let root = url.standardizedFileURL.resolvingSymlinksInPath()
      for key in language.modelBundle.componentKeys {
        let component = try language.modelBundle.requireModelURL(for: key)
          .standardizedFileURL.resolvingSymlinksInPath()
        guard ManagedModelAssetStore.isContained(component, in: root), component != root else {
          throw AdmissionError.escapingAssetPath(key)
        }
      }
      guard let tokenizer = language.tokenizerPath,
        ManagedModelAssetStore.isContained(tokenizer.resolvingSymlinksInPath(), in: root),
        LocalModelAsset.isReadableFile(
          at: tokenizer.appendingPathComponent("tokenizer.json"), extension: "json")
      else { throw AdmissionError.missingEmbeddedTokenizer }
    }
  }
}
