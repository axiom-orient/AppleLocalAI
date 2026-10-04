#if os(macOS)

  import Foundation

  /// I/O port for URLs returned by macOS document importers.
  protocol SecurityScopedResourceAccess: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
  }

  /// Owns balanced security-scoped access around synchronous and asynchronous file use.
  enum SecurityScopedResource {
    @MainActor
    static func withAccess<T>(
      to url: URL?,
      using access: any SecurityScopedResourceAccess,
      operation: @MainActor () async throws -> T
    ) async rethrows -> T {
      guard let url else { return try await operation() }
      let didStartAccessing = access.startAccessing(url)
      defer {
        if didStartAccessing { access.stopAccessing(url) }
      }
      return try await operation()
    }

    static func withAccess<T>(
      to url: URL,
      using access: any SecurityScopedResourceAccess,
      operation: () throws -> T
    ) rethrows -> T {
      let didStartAccessing = access.startAccessing(url)
      defer {
        if didStartAccessing { access.stopAccessing(url) }
      }
      return try operation()
    }
  }

  struct SystemSecurityScopedResourceAccess: SecurityScopedResourceAccess {
    func startAccessing(_ url: URL) -> Bool {
      url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
      url.stopAccessingSecurityScopedResource()
    }
  }

#endif
