import Foundation

/// Immutable import identity. The containing app resolves the root each launch;
/// an iOS sandbox container's absolute path is never the persisted identity.
public struct ManagedModelAsset: Codable, Equatable, Sendable {
  public let id: UUID
  public let fileName: String

  fileprivate init(id: UUID, fileName: String) {
    self.id = id
    self.fileName = fileName
  }
}

public enum ManagedModelAssetError: Error, LocalizedError, Sendable {
  case invalidSource
  case symbolicLinkOrSpecialFile(String)
  case invalidReference
  case rootInsideSource
  case cleanupFailed(primary: String, cleanup: String)

  public var errorDescription: String? {
    switch self {
    case .invalidSource: "A readable local file or directory is required."
    case .symbolicLinkOrSpecialFile(let path):
      "Symbolic links and special files are not admitted: \(path)"
    case .invalidReference: "The imported model reference is invalid or missing."
    case .rootInsideSource: "The model import root cannot be inside the selected source."
    case .cleanupFailed(let primary, let cleanup):
      "Import failed: \(primary). Staging cleanup also failed: \(cleanup)"
    }
  }
}

/// Filesystem mechanism only. Format validation is supplied by the model adapter.
/// Security-scoped access and asynchronous operation ownership belong to the app.
/// A successful import adds a unique immutable directory, never replaces a model
/// still in use. It proves local admission, not successful model load/inference.
public struct ManagedModelAssetStore: Sendable {
  public let root: URL

  public init(root: URL) { self.root = root.standardizedFileURL }

  public func resolve(_ asset: ManagedModelAsset) throws -> URL {
    guard validFileName(asset.fileName), root.isFileURL else {
      throw ManagedModelAssetError.invalidReference
    }
    let parent = root.appendingPathComponent(asset.id.uuidString, isDirectory: true)
    let url = parent.appendingPathComponent(asset.fileName)
    do {
      try rejectLinksAndSpecialFiles(at: root, recursively: false)
      try rejectLinksAndSpecialFiles(at: parent, recursively: false)
      try rejectLinksAndSpecialFiles(at: url, recursively: false)
    } catch {
      guard Self.isMissingResource(error) else { throw error }
      throw ManagedModelAssetError.invalidReference
    }
    return url
  }

  /// Call off the UI actor. Cancellation is checked at phase boundaries, including
  /// after copy (FileManager.copyItem itself is not cooperatively cancellable).
  public func importAsset(
    from source: URL,
    validate: @Sendable (URL) throws -> Void
  ) throws -> ManagedModelAsset {
    let files = FileManager.default
    guard source.isFileURL, root.isFileURL,
      validFileName(source.lastPathComponent),
      files.isReadableFile(atPath: source.path)
    else { throw ManagedModelAssetError.invalidSource }

    let source = source.standardizedFileURL
    let canonicalSource = source.resolvingSymlinksInPath()
    let canonicalRoot = root.resolvingSymlinksInPath()
    guard !Self.isContained(canonicalRoot, in: canonicalSource) else {
      throw ManagedModelAssetError.rootInsideSource
    }
    try Task.checkCancellation()
    // Validate the destination before createDirectory can follow a pre-existing
    // root symlink and redirect an import outside the configured store.
    try rejectExistingRoot()
    try rejectLinksAndSpecialFiles(at: source, recursively: true)
    try validate(source)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try rejectLinksAndSpecialFiles(at: root, recursively: false)

    let asset = ManagedModelAsset(id: UUID(), fileName: source.lastPathComponent)
    let staging = root.appendingPathComponent(".staging-\(asset.id.uuidString)", isDirectory: true)
    let destination = root.appendingPathComponent(asset.id.uuidString, isDirectory: true)
    let stagedAsset = staging.appendingPathComponent(asset.fileName)
    try files.createDirectory(at: staging, withIntermediateDirectories: false)
    do {
      try Task.checkCancellation()
      try files.copyItem(at: source, to: stagedAsset)
      try Task.checkCancellation()
      try rejectLinksAndSpecialFiles(at: stagedAsset, recursively: true)
      try validate(stagedAsset)
      try Task.checkCancellation()
      // Staging and destination share a parent/filesystem. No in-place overwrite.
      try files.moveItem(at: staging, to: destination)
      return asset
    } catch {
      let primary = error
      do { try files.removeItem(at: staging) } catch {
        throw ManagedModelAssetError.cleanupFailed(
          primary: primary.localizedDescription, cleanup: error.localizedDescription)
      }
      throw primary
    }
  }

  /// Only for an import that has NOT been published as the selected asset.
  /// No general deletion API: deleting an asset used by a session needs leases.
  public func discardUnpublished(_ asset: ManagedModelAsset) throws {
    _ = try resolve(asset)
    try FileManager.default.removeItem(
      at: root.appendingPathComponent(asset.id.uuidString, isDirectory: true))
  }

  public static func isContained(_ child: URL, in parent: URL) -> Bool {
    let parentParts = parent.standardizedFileURL.pathComponents
    let childParts = child.standardizedFileURL.pathComponents
    guard childParts.count >= parentParts.count else { return false }
    let caseSensitive = volumeSupportsCaseSensitiveNames(at: parent) ?? true
    let sameComponent: (String, String) -> Bool =
      caseSensitive
      ? { $0 == $1 }
      : { $0.compare($1, options: [.caseInsensitive, .literal]) == .orderedSame }
    return zip(childParts, parentParts).allSatisfy { sameComponent($0, $1) }
  }

  private func validFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
      && !name.contains("\\") && !name.contains("\0")
  }

  private static func isMissingResource(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == NSCocoaErrorDomain else { return false }
    return nsError.code == CocoaError.fileNoSuchFile.rawValue
      || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
  }

  private static func volumeSupportsCaseSensitiveNames(at url: URL) -> Bool? {
    var probe = url.standardizedFileURL
    while true {
      if let values = try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
        let result = values.volumeSupportsCaseSensitiveNames
      {
        return result
      }
      let parent = probe.deletingLastPathComponent()
      guard parent.path != probe.path else { return nil }
      probe = parent
    }
  }

  private func rejectLinksAndSpecialFiles(at url: URL, recursively: Bool) throws {
    let files = FileManager.default
    let attributes = try files.attributesOfItem(atPath: url.path)
    guard let kind = attributes[.type] as? FileAttributeType,
      kind == .typeRegular || kind == .typeDirectory
    else { throw ManagedModelAssetError.symbolicLinkOrSpecialFile(url.path) }
    guard recursively, kind == .typeDirectory else { return }
    // Walk explicitly: directory enumeration errors must not become silent success.
    for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
      try Task.checkCancellation()
      try rejectLinksAndSpecialFiles(at: child, recursively: true)
    }
  }

  private func rejectExistingRoot() throws {
    do {
      try rejectLinksAndSpecialFiles(at: root, recursively: false)
    } catch {
      // A new store root is valid and will be created below. Preserve every
      // other filesystem error and reject links/special files explicitly.
      guard Self.isMissingResource(error) else { throw error }
    }
  }
}
