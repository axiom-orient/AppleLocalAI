import AppleLocalAIFoundationModels
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAIMac

@MainActor
private final class SnapshotSettingsStore: ProviderSettingsStore {
  var value = ProviderSettings.standard

  func load() -> ProviderSettings { value }

  func save(_ settings: ProviderSettings) {
    value = settings
  }
}

@Suite("macOS Provider workspace")
@MainActor
struct ProviderSnapshotTests {
  @Test func staleCapabilitiesAreNotExposedAfterProviderInvalidation() {
    let capabilities = LanguageModelCapabilities([.vision])

    #expect(
      AppleIntelligenceModel.capabilitiesIfCurrent(capabilities, isCurrent: false) == nil)
    #expect(
      AppleIntelligenceModel.capabilitiesIfCurrent(capabilities, isCurrent: true)?.contains(.vision)
        == true)
  }

  @Test func coreAIPathIdentityTracksSymlinkTargetChanges() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppleLocalAI-CoreAIPath-\(UUID().uuidString)", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    let current = root.appendingPathComponent("current", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: current, withDestinationURL: first)

    let loadedIdentity = LocalModelResourceIdentity.normalizedDirectoryPath(current.path)
    #expect(loadedIdentity == LocalModelResourceIdentity.normalizedDirectoryPath(first.path))

    try FileManager.default.removeItem(at: current)
    try FileManager.default.createSymbolicLink(at: current, withDestinationURL: second)
    #expect(
      loadedIdentity != LocalModelResourceIdentity.normalizedDirectoryPath(current.path))
  }

  @Test func everyProviderIsDirectlySelectableFromOneAuthority() {
    let store = SnapshotSettingsStore()
    let model = AppleIntelligenceModel(settingsStore: store)

    #expect(model.provider == .apple)

    for provider in LocalProviderChoice.allCases {
      model.selectProvider(provider)
      #expect(model.provider == provider)
      #expect(store.value.provider == provider)
      #expect(store.value.workload == .manual)
    }
  }

  @Test func exposesEveryProviderAndKeepsSelectionActionable() {
    let model = AppleIntelligenceModel(settingsStore: SnapshotSettingsStore())

    #expect(model.providerSnapshots.count == LocalProviderChoice.allCases.count)
    #expect(model.providerSnapshots.map(\.provider).contains(.privateCloud))
    #expect(model.providerSnapshot(for: .remote).readiness == .invalidConfiguration)

    model.selectProvider(.remote)
    #expect(model.provider == .remote)
    #expect(model.selectedProviderSnapshot.provider == .remote)
    #expect(model.selectedProviderSnapshot.status == "URL과 모델 이름 필요")

    model.selectProvider(.privateCloud)
    #expect(model.provider == .privateCloud)
  }
}
