import Foundation

/// Container identification only; it does not establish model or backend support.
/// Model names and quantization marketing labels are deliberately not inputs.
public enum LocalModelFileFormat: String, Sendable {
  case gguf
  case liteRT
  case unknown

  public static func inspect(_ url: URL) -> Self {
    guard url.isFileURL,
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true,
      let file = try? FileHandle(forReadingFrom: url)
    else { return .unknown }
    defer { try? file.close() }
    guard let header = try? file.read(upToCount: 8) else { return .unknown }
    if header.starts(with: Data("GGUF".utf8)) { return .gguf }
    if header == Data("LITERTLM".utf8) { return .liteRT }
    return .unknown
  }
}

public enum LocalModelAssetError: Error, LocalizedError, Sendable {
  case unsupportedGGUF

  public var errorDescription: String? {
    "This file is GGUF. The configured native Swift MLX and LiteRT loaders require an MLX safetensors model directory or a converted .litertlm bundle. Renaming the file does not convert it."
  }
}
