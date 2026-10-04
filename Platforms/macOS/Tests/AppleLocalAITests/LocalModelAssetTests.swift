import AppleLocalAIHost
import AppleLocalAILocalModels
import Foundation
import Testing

struct LocalModelAssetTests {
  @Test func rejectsDirectoriesEmptyAndMissingAssets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let asset = root.appendingPathComponent("model.litertlm")
    #expect(!LocalModelAsset.isReadableFile(at: asset, extension: "litertlm"))
    try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: false)
    #expect(!LocalModelAsset.isReadableFile(at: asset, extension: "litertlm"))
    try FileManager.default.removeItem(at: asset)
    try Data().write(to: asset)
    #expect(!LocalModelAsset.isReadableFile(at: asset, extension: "litertlm"))
    try Data([1]).write(to: asset)
    #expect(LocalModelAsset.isReadableFile(at: asset, extension: "litertlm"))
  }

  @Test func endpointRejectsInvalidPorts() {
    for port in ["0", "65536", "99999"] {
      #expect(
        RemoteLanguageModelConfiguration.endpointURL(from: "http://127.0.0.1:\(port)/v1") == nil)
    }
    #expect(RemoteLanguageModelConfiguration.endpointURL(from: "http://127.0.0.1:65535/v1") != nil)
  }

  @Test func mlxDirectoryRequiresRuntimeDispatchMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
    try Data([1]).write(to: root.appendingPathComponent("model.safetensors"))
    #expect(!LocalModelAsset.isMLXModelDirectory(at: root))

    try Data(#"{"model_type":"llama"}"#.utf8).write(
      to: root.appendingPathComponent("config.json"))
    #expect(LocalModelAsset.isMLXModelDirectory(at: root))

    try FileManager.default.removeItem(at: root.appendingPathComponent("model.safetensors"))
    #expect(!LocalModelAsset.isMLXModelDirectory(at: root))
  }

  @Test func mlxDirectoryRejectsSymlinkedRequiredFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    try Data(#"{"model_type":"llama"}"#.utf8)
      .write(to: outside.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: outside.appendingPathComponent("tokenizer.json"))
    try Data([1]).write(to: outside.appendingPathComponent("model.safetensors"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("config.json"),
      withDestinationURL: outside.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
    try Data([1]).write(to: root.appendingPathComponent("model.safetensors"))
    #expect(!LocalModelAsset.isMLXModelDirectory(at: root))

    try FileManager.default.removeItem(at: root.appendingPathComponent("config.json"))
    try Data(#"{"model_type":"llama"}"#.utf8)
      .write(to: root.appendingPathComponent("config.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("model.safetensors"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("model.safetensors"),
      withDestinationURL: outside.appendingPathComponent("model.safetensors"))
    #expect(!LocalModelAsset.isMLXModelDirectory(at: root))
  }

  @Test func mlxConfigurationReadIsBounded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let oversized = Data(repeating: 0x20, count: (4 * 1024 * 1024) + 1)
    try oversized.write(to: root.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
    try Data([1]).write(to: root.appendingPathComponent("model.safetensors"))

    #expect(!LocalModelAsset.isMLXModelDirectory(at: root))
  }

  @Test func visionAdmissionUsesMetadataNotDirectoryName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config.json")
    try Data(#"{"model_type":"anonymous"}"#.utf8).write(to: config)
    try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
    try Data([1]).write(to: root.appendingPathComponent("model.safetensors"))
    #expect(LocalModelAsset.isMLXModelDirectory(at: root))
    #expect(!LocalModelAsset.isMLXVLMModelDirectory(at: root))
    try Data(#"{"model_type":"anonymous","vision_config":{}}"#.utf8).write(to: config)
    #expect(!LocalModelAsset.isMLXVLMModelDirectory(at: root))
    let processor = root.appendingPathComponent("processor_config.json")
    try Data("{}".utf8).write(to: processor)
    #expect(LocalModelAsset.isMLXVLMModelDirectory(at: root))
    // Structural admission is deliberately not a registry/loadability claim.
    try FileManager.default.moveItem(
      at: processor, to: root.appendingPathComponent("preprocessor_config.json"))
    #expect(LocalModelAsset.isMLXVLMModelDirectory(at: root))
    try FileManager.default.removeItem(at: root.appendingPathComponent("tokenizer.json"))
    #expect(!LocalModelAsset.isMLXVLMModelDirectory(at: root))
  }
}
