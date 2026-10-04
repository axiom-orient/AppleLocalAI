import Foundation
import Testing
@testable import AppleLocalAILiteRT

@Suite struct LiteRTSettingsTests {
  @Test func defaultsMissingOptionalFieldsWithoutInventingAPath() throws {
    let data = Data(#"{"modelPath":"/tmp/model.litertlm"}"#.utf8)
    let value = try JSONDecoder().decode(LiteRTProviderSettings.self, from: data)
    #expect(value.modelPath == "/tmp/model.litertlm")
    #expect(value.backend == .gpu)
    #expect(value.visionBackend == .disabled)
  }

  @Test func modelIdentifierIsPresentationOnly() {
    let value = LiteRTProviderSettings(
      modelPath: "/Models/gemma.litertlm",
      backend: .gpu,
      visionBackend: .cpu
    )
    #expect(value.modelIdentifier == "gemma")
  }
}
