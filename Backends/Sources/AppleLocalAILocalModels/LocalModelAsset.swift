import Foundation

/// File admission only. Engine load and inference remain runtime authorities.
public enum LocalModelAsset {
  private static let maximumConfigurationBytes = 4 * 1024 * 1024

  /// Returns the filesystem identity used by model admission, inspection and
  /// construction. Imported model stores may expose a bundle through a
  /// symlink; checking the link itself can make a valid regular file appear to
  /// be non-regular to URL resource queries.
  static func canonicalURL(for url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  public static func isReadableFile(at url: URL, extension expectedExtension: String) -> Bool {
    guard url.isFileURL, url.pathExtension.lowercased() == expectedExtension else {
      return false
    }
    return isReadableNonEmptyRegularFile(at: url)
  }

  /// Checks the file contract required before the Swift MLX loader is invoked.
  ///
  /// `mlx-swift-lm` dispatches from the JSON `model_type`; the directory name,
  /// Python `auto_map`, and a merely present config file are not sufficient
  /// evidence that this process can load the model. This remains a preflight
  /// check, not a replacement for the runtime's architecture/weight decoder.
  public static func isMLXModelDirectory(at url: URL) -> Bool {
    guard url.isFileURL, isDirectory(at: url) else { return false }

    let configuration = url.appendingPathComponent("config.json")
    let tokenizer = url.appendingPathComponent("tokenizer.json")
    guard isReadableNonEmptyRegularFile(at: configuration),
      isReadableNonEmptyRegularFile(at: tokenizer),
      let object = readJSONObject(at: configuration),
      let modelType = object["model_type"] as? String,
      !modelType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }

    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    return files.contains {
      $0.pathExtension.lowercased() == "safetensors"
        && isReadableNonEmptyRegularFile(at: $0)
    }
  }

  /// Checks the additional metadata contract needed before dispatching to the
  /// official `MLXVLM` factory. The factory remains the authority for the
  /// model/processor implementation; this only distinguishes a vision bundle
  /// from a text-only MLX bundle before capabilities are advertised.
  public static func isMLXVLMModelDirectory(at url: URL) -> Bool {
    guard isMLXModelDirectory(at: url) else { return false }

    let configuration = url.appendingPathComponent("config.json")
    let processor = url.appendingPathComponent("processor_config.json")
    let preprocessor = url.appendingPathComponent("preprocessor_config.json")
    guard let object = readJSONObject(at: configuration),
      object["vision_config"] is [String: Any],
      isReadableNonEmptyRegularFile(at: processor)
        || isReadableNonEmptyRegularFile(at: preprocessor)
    else {
      return false
    }

    return true
  }

  private static func isDirectory(at url: URL) -> Bool {
    guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return false
    }
    return values[.type] as? FileAttributeType == .typeDirectory
      && FileManager.default.isReadableFile(atPath: url.path)
  }

  private static func readJSONObject(at url: URL) -> [String: Any]? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }

    guard let data = try? file.read(upToCount: maximumConfigurationBytes + 1),
      data.count <= maximumConfigurationBytes
    else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private static func isReadableNonEmptyRegularFile(at url: URL) -> Bool {
    guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
      values[.type] as? FileAttributeType == .typeRegular,
      (values[.size] as? NSNumber)?.int64Value ?? 0 > 0
    else {
      return false
    }
    return FileManager.default.isReadableFile(atPath: url.path)
  }
}
