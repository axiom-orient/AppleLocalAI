#if os(macOS)

  import Foundation

  /// Canonicalizes local resource paths consistently across Mac app and Provider targets.
  package enum LocalModelResourceIdentity {
    package static func normalizedDirectoryPath(_ path: String) -> String {
      normalizedPath(path, isDirectory: true)
    }

    package static func normalizedFilePath(_ path: String) -> String {
      normalizedPath(path, isDirectory: false)
    }

    private static func normalizedPath(_ path: String, isDirectory: Bool) -> String {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return "" }
      return URL(fileURLWithPath: trimmed, isDirectory: isDirectory)
        .standardizedFileURL.resolvingSymlinksInPath().path
    }
  }

#endif
