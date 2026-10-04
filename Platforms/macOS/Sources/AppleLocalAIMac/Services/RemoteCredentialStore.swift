#if os(macOS)

  import AppleLocalAIHost
  import Foundation
  import Security

  @MainActor
  protocol RemoteCredentialStore {
    func load() throws -> String?
    func save(_ secret: String?) throws
  }

  struct KeychainRemoteCredentialStore: RemoteCredentialStore {
    private let service = "com.applelocalai.mac.remote-language-model"
    private let account = "default-api-key"

    func load() throws -> String? {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else { throw RemoteCredentialError.keychain(status) }
      guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        throw RemoteCredentialError.invalidData
      }
      return try RemoteCredentialPolicy.normalized(value)
    }

    func save(_ secret: String?) throws {
      let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
      ]
      guard let normalized = try RemoteCredentialPolicy.normalized(secret) else {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw RemoteCredentialError.keychain(status)
        }
        return
      }
      let data = Data(normalized.utf8)
      let update = [kSecValueData as String: data]
      let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
      if updateStatus == errSecItemNotFound {
        var add = base
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RemoteCredentialError.keychain(addStatus) }
      } else if updateStatus != errSecSuccess {
        throw RemoteCredentialError.keychain(updateStatus)
      }
    }
  }

  enum RemoteCredentialError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
      switch self {
      case .keychain(let status):
        return SecCopyErrorMessageString(status, nil) as String?
          ?? "Keychain operation failed (\(status))."
      case .invalidData:
        return "The stored remote API key is not valid UTF-8."
      }
    }
  }

#endif
