import Foundation
import Testing

@testable import AppleLocalAIHost

@Test func remoteCredentialPolicyRejectsHeaderControlsAndOversizedValues() throws {
  #expect(try RemoteCredentialPolicy.normalized(nil) == nil)
  #expect(try RemoteCredentialPolicy.normalized("  valid-key  ") == "valid-key")
  #expect(throws: RemoteCredentialPolicyError.self) {
    try RemoteCredentialPolicy.normalized("valid\r\nX-Injected: true")
  }
  #expect(throws: RemoteCredentialPolicyError.self) {
    try RemoteCredentialPolicy.normalized("valid\u{0085}credential")
  }
  #expect(throws: RemoteCredentialPolicyError.self) {
    try RemoteCredentialPolicy.normalized(
      String(repeating: "a", count: RemoteCredentialPolicy.maximumUTF8Bytes + 1))
  }
}
