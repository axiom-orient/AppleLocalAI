#if os(macOS)

  import Foundation

  @MainActor
  protocol ProviderSettingsStore {
    /// A recoverable persistence problem is observable by the UI. Implementations
    /// may keep this nil when they do not persist settings themselves.
    var persistenceErrorMessage: String? { get }
    func load() -> ProviderSettings
    func save(_ settings: ProviderSettings)
  }

  extension ProviderSettingsStore {
    var persistenceErrorMessage: String? { nil }
  }

  @MainActor
  final class UserDefaultsProviderSettingsStore: ProviderSettingsStore {
    static let storageKey = "com.applelocalai.mac.provider-settings"
    static let maximumPersistedSettingsBytes = 1 * 1024 * 1024

    private static let unreadableSettingsMessage =
      "저장된 Provider 설정을 읽지 못해 기본 설정으로 시작합니다."
    private static let oversizedSettingsMessage =
      "Provider 설정이 너무 커서 저장하거나 읽을 수 없습니다. 현재 실행 상태는 유지됩니다."

    private let defaults: UserDefaults
    private(set) var persistenceErrorMessage: String?

    init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
    }

    func load() -> ProviderSettings {
      guard let storedValue = defaults.object(forKey: Self.storageKey) else {
        persistenceErrorMessage = nil
        return .standard
      }

      guard let data = storedValue as? Data else {
        persistenceErrorMessage = Self.unreadableSettingsMessage
        return .standard
      }

      guard data.count <= Self.maximumPersistedSettingsBytes else {
        persistenceErrorMessage = Self.oversizedSettingsMessage
        return .standard
      }

      do {
        let settings = try JSONDecoder().decode(ProviderSettings.self, from: data)
        persistenceErrorMessage = nil
        return settings
      } catch {
        // Keep the malformed value untouched so recovery can be diagnosed and
        // the next successful save is the explicit replacement boundary.
        persistenceErrorMessage = Self.unreadableSettingsMessage
        return .standard
      }
    }

    func save(_ settings: ProviderSettings) {
      do {
        let data = try JSONEncoder().encode(settings)
        guard data.count <= Self.maximumPersistedSettingsBytes else {
          persistenceErrorMessage = Self.oversizedSettingsMessage
          return
        }
        defaults.set(data, forKey: Self.storageKey)
        persistenceErrorMessage = nil
      } catch {
        persistenceErrorMessage = "Provider 설정을 저장하지 못했습니다. 현재 실행 상태는 유지됩니다."
      }
    }
  }

#endif
