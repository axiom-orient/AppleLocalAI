import Foundation
import Testing

@testable import AppleLocalAILocalModels

@Test func missingManagedReferenceUsesTheTypedError() throws {
  try withTemporaryDirectory { root in
    let store = ManagedModelAssetStore(root: root.appendingPathComponent("managed"))
    let asset = try makeAsset()

    do {
      _ = try store.resolve(asset)
      Issue.record("A missing managed asset reference was accepted.")
    } catch let error as ManagedModelAssetError {
      guard case .invalidReference = error else {
        Issue.record("Unexpected managed asset error: \(error)")
        return
      }
    }
  }
}

@Test func nonMissingManagedFilesystemFailureIsNotRewritten() throws {
  try withTemporaryDirectory { root in
    let store = ManagedModelAssetStore(root: root.appendingPathComponent("managed"))
    try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: false)
    let asset = try makeAsset()
    let published = store.root.appendingPathComponent(asset.id.uuidString, isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: published, withDestinationURL: outside)

    do {
      _ = try store.resolve(asset)
      Issue.record("A symbolic-link managed asset reference was accepted.")
    } catch let error as ManagedModelAssetError {
      guard case .symbolicLinkOrSpecialFile(let path) = error else {
        Issue.record("Unexpected managed asset error: \(error)")
        return
      }
      #expect(path == published.path)
    }
  }
}

@Test func importRejectsASymlinkedRootBeforeWritingOutsideTheStore() throws {
  try withTemporaryDirectory { root in
    let source = root.appendingPathComponent("model.litertlm")
    try Data("LITERTLMfixture".utf8).write(to: source)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let linkedRoot = root.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
    let store = ManagedModelAssetStore(root: linkedRoot)

    do {
      _ = try store.importAsset(from: source) { _ in }
      Issue.record("A symlinked managed root was accepted.")
    } catch let error as ManagedModelAssetError {
      guard case .symbolicLinkOrSpecialFile(let path) = error else {
        Issue.record("Unexpected managed asset error: \(error)")
        return
      }
      #expect(path == linkedRoot.path)
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }
}

@Test func containmentFollowsFilesystemCaseSensitivityOrSafeFallback() throws {
  try withTemporaryDirectory { root in
    let parent = root.appendingPathComponent("Parent", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let variant = root.appendingPathComponent("parent", isDirectory: true)
      .appendingPathComponent("managed", isDirectory: true)
    let values = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    let expected = values.volumeSupportsCaseSensitiveNames.map { !$0 } ?? false
    #expect(ManagedModelAssetStore.isContained(variant, in: parent) == expected)
  }
}

@Test func liteRTCapabilityInspectionUsesTheResolvedBundleIdentity() throws {
  try withTemporaryDirectory { root in
    let bundle = root.appendingPathComponent("model.litertlm")
    try Data("LITERTLM".utf8).write(to: bundle)
    let link = root.appendingPathComponent("selected.litertlm")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

    #expect(
      LocalModelAsset.canonicalURL(for: link).path
        == bundle.standardizedFileURL.path)
  }
}

private func makeAsset() throws -> ManagedModelAsset {
  let id = UUID().uuidString
  let data = try JSONSerialization.data(withJSONObject: ["id": id, "fileName": "model.bin"])
  return try JSONDecoder().decode(ManagedModelAsset.self, from: data)
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AppleLocalAI-ManagedAssetTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}
