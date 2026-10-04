import Foundation
import Testing

@testable import AppleLocalAILocalModels

@Test func rejectsRenamedGGUFAndEmptyMLXWeights() throws {
  try withTemporaryDirectory { root in
    let renamed = root.appendingPathComponent("renamed.litertlm")
    try Data("GGUFnot-a-litert-model".utf8).write(to: renamed)
    #expect(LocalModelFileFormat.inspect(renamed) == .gguf)
    #expect(throws: LocalModelAssetAdmission.AdmissionError.self) {
      try LocalModelAssetAdmission.validate(renamed, as: .liteRT)
    }

    let mlx = root.appendingPathComponent("mlx", isDirectory: true)
    try FileManager.default.createDirectory(at: mlx, withIntermediateDirectories: false)
    try Data(#"{"model_type":"test"}"#.utf8).write(to: mlx.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: mlx.appendingPathComponent("tokenizer.json"))
    let weights = mlx.appendingPathComponent("model.safetensors")
    try Data().write(to: weights)
    #expect(!LocalModelAsset.isMLXModelDirectory(at: mlx))
    try Data([1]).write(to: weights)
    // Admission checks only file shape, never proves model loading or inference.
    #expect(LocalModelAsset.isMLXModelDirectory(at: mlx))
  }
}

@Test func importCopiesAnImmutableAssetAndRoundTripsItsRelativeIdentity() throws {
  try withTemporaryDirectory { root in
    let source = root.appendingPathComponent("model.litertlm")
    let bytes = Data("LITERTLMfixture".utf8)
    try bytes.write(to: source)
    let store = ManagedModelAssetStore(root: root.appendingPathComponent("managed"))
    let asset = try store.importAsset(from: source) {
      try LocalModelAssetAdmission.validate($0, as: .liteRT)
    }
    let restored = try JSONDecoder().decode(
      ManagedModelAsset.self, from: JSONEncoder().encode(asset))
    #expect(restored == asset)
    #expect(try Data(contentsOf: store.resolve(restored)) == bytes)
    try Data("changed".utf8).write(to: source)
    #expect(try Data(contentsOf: store.resolve(asset)) == bytes)
    try store.discardUnpublished(asset)
    do {
      _ = try store.resolve(asset)
      Issue.record("A discarded asset reference was accepted.")
    } catch let error as ManagedModelAssetError {
      guard case .invalidReference = error else {
        Issue.record("Unexpected managed asset error: \(error)")
        return
      }
    }
  }
}

@Test func rejectedStagedImportLeavesNoPublishedOrStagingAsset() throws {
  enum ProbeError: Error { case stagedValidationFailed }
  try withTemporaryDirectory { root in
    let source = root.appendingPathComponent("model.litertlm")
    try Data("LITERTLMfixture".utf8).write(to: source)
    let destination = root.appendingPathComponent("managed")
    let store = ManagedModelAssetStore(root: destination)
    #expect(throws: ProbeError.self) {
      _ = try store.importAsset(from: source) { url in
        if url.deletingLastPathComponent().lastPathComponent.hasPrefix(".staging-") {
          throw ProbeError.stagedValidationFailed
        }
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
  }
}

@Test func resolvePreservesNonMissingFilesystemFailures() throws {
  try withTemporaryDirectory { root in
    let source = root.appendingPathComponent("model.litertlm")
    try Data("LITERTLMfixture".utf8).write(to: source)
    let store = ManagedModelAssetStore(root: root.appendingPathComponent("managed"))
    let asset = try store.importAsset(from: source) { _ in }
    let published = store.root.appendingPathComponent(asset.id.uuidString, isDirectory: true)
    try FileManager.default.removeItem(at: published)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: published, withDestinationURL: outside)

    do {
      _ = try store.resolve(asset)
      Issue.record("A symbolic-link asset reference was accepted.")
    } catch let error as ManagedModelAssetError {
      guard case .symbolicLinkOrSpecialFile = error else {
        Issue.record("Unexpected managed asset error: \(error)")
        return
      }
    }
  }
}

@Test func containmentFollowsTheFilesystemCaseSensitivityRule() throws {
  try withTemporaryDirectory { root in
    let parent = root.appendingPathComponent("Parent", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let variant = root.appendingPathComponent("parent", isDirectory: true)
      .appendingPathComponent("managed", isDirectory: true)
    let values = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    let caseSensitive = try #require(values.volumeSupportsCaseSensitiveNames as Bool?)
    #expect(ManagedModelAssetStore.isContained(variant, in: parent) == !caseSensitive)
  }
}

@Test func importRejectsNestedSymlinksAndARootInsideTheSource() throws {
  try withTemporaryDirectory { root in
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let outside = root.appendingPathComponent("outside")
    try Data([1]).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: source.appendingPathComponent("weights"), withDestinationURL: outside)
    let store = ManagedModelAssetStore(root: root.appendingPathComponent("managed"))
    #expect(throws: ManagedModelAssetError.self) {
      _ = try store.importAsset(from: source) { _ in }
    }

    let nested = ManagedModelAssetStore(root: source.appendingPathComponent("managed"))
    #expect(throws: ManagedModelAssetError.self) {
      _ = try nested.importAsset(from: source) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: nested.root.path))
  }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AppleLocalAI-LocalModels-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}
