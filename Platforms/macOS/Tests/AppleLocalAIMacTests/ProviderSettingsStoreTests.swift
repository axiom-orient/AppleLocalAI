import AppleLocalAIFoundationModels
import AppleLocalAIHost
import Foundation
import Testing

@testable import AppleLocalAIMac

@Suite("Provider settings persistence")
@MainActor
struct ProviderSettingsStoreTests {
  @Test func missingSettingsDoNotWriteDefaults() throws {
    try withIsolatedDefaults { defaults in
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)
      #expect(store.load() == .standard)
      #expect(store.persistenceErrorMessage == nil)
      #expect(defaults.object(forKey: UserDefaultsProviderSettingsStore.storageKey) == nil)
    }
  }

  @Test func explicitSaveRoundTripsCanonicalSelectionAndConsent() throws {
    try withIsolatedDefaults { defaults in
      var settings = ProviderSettings.standard
      settings.provider = .remote
      settings.workload = .manual
      settings.allowPrivateCloud = true
      settings.remote.baseURL = "https://example.invalid/v1"
      settings.remote.modelName = "chosen-model"
      settings.remote.toolCalling = true
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)
      store.save(settings)

      #expect(store.persistenceErrorMessage == nil)
      let reloaded = UserDefaultsProviderSettingsStore(defaults: defaults)
      #expect(reloaded.load() == settings)
      #expect(reloaded.persistenceErrorMessage == nil)
    }
  }

  @Test func corruptCanonicalDataIsPreserved() throws {
    try withIsolatedDefaults { defaults in
      let corrupt = Data("not-json".utf8)
      defaults.set(corrupt, forKey: UserDefaultsProviderSettingsStore.storageKey)
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)

      #expect(store.load() == .standard)
      #expect(store.persistenceErrorMessage != nil)
      #expect(defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey) == corrupt)
    }
  }

  @Test func wrongStoredTypeIsAnObservableErrorAndIsNotReplaced() throws {
    try withIsolatedDefaults { defaults in
      defaults.set("not-data", forKey: UserDefaultsProviderSettingsStore.storageKey)
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)

      #expect(store.load() == .standard)
      #expect(store.persistenceErrorMessage != nil)
      #expect(defaults.string(forKey: UserDefaultsProviderSettingsStore.storageKey) == "not-data")
    }
  }

  @Test func encodingFailurePreservesLastSavedValueUntilExplicitSuccessfulSave() throws {
    try withIsolatedDefaults { defaults in
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)
      store.save(.standard)
      let saved = try #require(defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey))
      var invalid = ProviderSettings.standard
      invalid.foundationModels.temperature = .nan
      store.save(invalid)

      #expect(store.persistenceErrorMessage != nil)
      #expect(defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey) == saved)
      store.save(.standard)
      #expect(store.persistenceErrorMessage == nil)
      #expect(store.load() == .standard)
    }
  }

  @Test func oversizedStoredSettingsArePreservedWithoutDecoding() throws {
    try withIsolatedDefaults { defaults in
      var oversized = ProviderSettings.standard
      oversized.coreAIModelPath = String(
        repeating: "x", count: UserDefaultsProviderSettingsStore.maximumPersistedSettingsBytes)
      let data = try JSONEncoder().encode(oversized)
      #expect(data.count > UserDefaultsProviderSettingsStore.maximumPersistedSettingsBytes)
      defaults.set(data, forKey: UserDefaultsProviderSettingsStore.storageKey)
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)

      #expect(store.load() == .standard)
      #expect(store.persistenceErrorMessage != nil)
      #expect(defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey) == data)
    }
  }

  @Test func oversizedSavePreservesTheLastCommittedValue() throws {
    try withIsolatedDefaults { defaults in
      let store = UserDefaultsProviderSettingsStore(defaults: defaults)
      store.save(.standard)
      let saved = try #require(defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey))

      var oversized = ProviderSettings.standard
      oversized.coreAIModelPath = String(
        repeating: "x", count: UserDefaultsProviderSettingsStore.maximumPersistedSettingsBytes)
      store.save(oversized)

      #expect(store.persistenceErrorMessage != nil)
      #expect(defaults.data(forKey: UserDefaultsProviderSettingsStore.storageKey) == saved)
    }
  }

  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "AppleLocalAI.ProviderSettingsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
  }
}
