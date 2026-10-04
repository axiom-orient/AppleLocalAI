import Foundation

package enum RemoteCredentialPolicy {
  package static let maximumUTF8Bytes = 8 * 1024

  package static func normalized(_ secret: String?) throws -> String? {
    let value = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty else { return nil }
    guard value.utf8.count <= maximumUTF8Bytes,
      value.unicodeScalars.allSatisfy({ scalar in
        let codePoint = scalar.value
        return codePoint >= 0x20 && !(0x7F...0x9F).contains(codePoint)
          && codePoint != 0x2028 && codePoint != 0x2029
      })
    else {
      throw RemoteCredentialPolicyError.invalidSecret
    }
    return value
  }
}

package enum RemoteCredentialPolicyError: Error, LocalizedError, Sendable, Equatable {
  case invalidSecret

  package var errorDescription: String? {
    "The remote API key must contain no control characters and be at most 8 KiB."
  }
}
