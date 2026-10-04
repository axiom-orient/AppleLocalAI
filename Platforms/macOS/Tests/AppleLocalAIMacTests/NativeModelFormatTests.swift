import AppleLocalAIFoundationModels
import AppleLocalAILocalModels
import Foundation
import Testing

@Suite struct NativeModelFormatTests {
  @Test func detectsContentWithoutTrustingModelNameOrExtension() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for name in ["model.gguf", "model.litertlm", "weights.safetensors", "renamed"] {
      let url = root.appendingPathComponent(name)
      try Data([0x47, 0x47, 0x55, 0x46, 3, 0, 0, 0]).write(to: url)
      #expect(LocalModelFileFormat.inspect(url) == .gguf)
      #expect(LiteRTModelInspector.capabilities(for: url) == nil)
      #expect(throws: LocalModelAssetError.self) {
        _ = try LocalLanguageModels.mlx(directory: url, capabilities: [])
      }
      #expect(throws: LocalModelAssetError.self) {
        _ = try LocalLanguageModels.liteRT(path: url.path, useCPU: true)
      }
    }
    let truncated = root.appendingPathComponent("truncated.litertlm")
    try Data("LITER".utf8).write(to: truncated)
    #expect(LocalModelFileFormat.inspect(truncated) == .unknown)
    #expect(LocalModelFileFormat.inspect(root) == .unknown)
    #expect(LocalModelFileFormat.inspect(root.appendingPathComponent("missing")) == .unknown)
    try Data("LITERTLM".utf8).write(to: truncated)
    #expect(LocalModelFileFormat.inspect(truncated) == .liteRT)
    // Recognizing a header must never turn an incomplete bundle into a usable model.
    #expect(LiteRTModelInspector.capabilities(for: truncated) == nil)
  }
}
