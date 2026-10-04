import CryptoKit
import Foundation
import Testing

@testable import AppleLocalAILEAP

@Test func artifactStoreReusesVerifiedCacheWithoutTransport() async throws {
  let fixture = try ArtifactFixture()
  try fixture.contents.write(to: fixture.destination)

  #expect(try await fixture.prepare() == [fixture.destination])
  #expect(fixture.transport.requests.isEmpty)
}

@Test(
  arguments: [
    "", ".", "..", "../escape.bundle", "nested/escape.bundle", "/tmp/escape.bundle",
    "escape\\bundle",
  ])
func artifactStoreRejectsNonLeafArtifactNames(fileName: String) async throws {
  let fixture = try ArtifactFixture()
  let artifact = LEAPArtifactFile(
    fileName: fileName,
    remoteURL: fixture.artifact.remoteURL,
    byteCount: fixture.artifact.byteCount,
    sha256: fixture.artifact.sha256)

  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await LEAPArtifactStore.prepare(
      files: [artifact], rootURL: fixture.root, minimumFreeBytes: 0, progress: nil,
      sessionConfiguration: fixture.sessionConfiguration)
  }
  #expect(fixture.transport.requests.isEmpty)
}

@Test func artifactStoreRejectsDuplicateArtifactNamesBeforeFilesystemWork() async throws {
  let fixture = try ArtifactFixture()

  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await LEAPArtifactStore.prepare(
      files: [fixture.artifact, fixture.artifact], rootURL: fixture.root,
      minimumFreeBytes: 0, progress: nil,
      sessionConfiguration: fixture.sessionConfiguration)
  }
  #expect(fixture.transport.requests.isEmpty)
}

@Test func artifactStoreDoesNotReserveDiskForAValidCache() async throws {
  let fixture = try ArtifactFixture()
  try fixture.contents.write(to: fixture.destination)

  let paths = try await LEAPArtifactStore.prepare(
    files: [fixture.artifact],
    rootURL: fixture.root,
    minimumFreeBytes: 1,
    progress: nil,
    capacityProvider: { _ in 0 })

  #expect(paths == [fixture.destination])
  #expect(fixture.transport.requests.isEmpty)
}

@Test func artifactStoreReservesOnlyTheAdditionalStagingBytes() async throws {
  let fixture = try ArtifactFixture()
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ArtifactURLProtocol.self]

  let paths = try await LEAPArtifactStore.prepare(
    files: [fixture.artifact],
    rootURL: fixture.root,
    minimumFreeBytes: 1,
    progress: nil,
    sessionConfiguration: configuration,
    capacityProvider: { _ in UInt64(fixture.contents.count) + 1 })

  #expect(paths == [fixture.destination])
  #expect(fixture.transport.requests.count == 1)
}

@Test func artifactStoreReplacesAnInvalidCachedArtifact() async throws {
  let fixture = try ArtifactFixture()
  try Data("broken".utf8).write(to: fixture.destination)

  _ = try await fixture.prepare()

  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
  #expect(fixture.transport.requests.count == 1)
}

@Test func artifactStoreDoesNotAcceptASymlinkedCachedArtifact() async throws {
  let fixture = try ArtifactFixture()
  let outside = FileManager.default.temporaryDirectory
    .appendingPathComponent("LEAPArtifactStore-outside-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: outside) }
  try fixture.contents.write(to: outside)
  try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: outside)

  _ = try await fixture.prepare()

  #expect(fixture.transport.requests.count == 1)
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
  #expect(
    (try FileManager.default.attributesOfItem(atPath: fixture.destination.path))[.type]
      as? FileAttributeType == .typeRegular)
  #expect(try Data(contentsOf: outside) == fixture.contents)
}

@Test func artifactStoreDoesNotWriteThroughASymlinkedStagingFile() async throws {
  let fixture = try ArtifactFixture()
  let outside = FileManager.default.temporaryDirectory
    .appendingPathComponent("LEAPArtifactStore-outside-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: outside) }
  try Data("outside".utf8).write(to: outside)
  try FileManager.default.createSymbolicLink(at: fixture.staging, withDestinationURL: outside)

  _ = try await fixture.prepare()

  #expect(fixture.transport.requests.count == 1)
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
  #expect(try Data(contentsOf: outside) == Data("outside".utf8))
}

@Test func artifactStoreRejectsASymlinkedRootBeforeAcquiringTheLease() async throws {
  let fixture = try ArtifactFixture()
  let outside = FileManager.default.temporaryDirectory
    .appendingPathComponent("LEAPArtifactStore-root-outside-\(UUID().uuidString)")
  let linkedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("LEAPArtifactStore-root-link-\(UUID().uuidString)")
  defer {
    try? FileManager.default.removeItem(at: linkedRoot)
    try? FileManager.default.removeItem(at: outside)
  }
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

  do {
    _ = try await LEAPArtifactStore.prepare(
      files: [fixture.artifact], rootURL: linkedRoot, minimumFreeBytes: 0, progress: nil,
      sessionConfiguration: fixture.sessionConfiguration)
    Issue.record("A symbolic-link artifact root was accepted.")
  } catch AppleLocalAILEAPError.invalidArtifactRoot {
    // The store must reject the root before opening its lock or transport.
  } catch {
    Issue.record("Unexpected artifact-root error: \(error)")
  }
  #expect(fixture.transport.requests.isEmpty)
  #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func runtimeInitializersRejectASymlinkedRootBeforeCreatingDirectories() throws {
  let outside = FileManager.default.temporaryDirectory
    .appendingPathComponent("LEAPRuntime-root-outside-\(UUID().uuidString)")
  let linkedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("LEAPRuntime-root-link-\(UUID().uuidString)")
  defer {
    try? FileManager.default.removeItem(at: linkedRoot)
    try? FileManager.default.removeItem(at: outside)
  }
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
  try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

  do {
    _ = try AppleLocalAILEAPRuntime(rootURL: linkedRoot)
    Issue.record("The text runtime accepted a symbolic-link root.")
  } catch AppleLocalAILEAPError.invalidArtifactRoot {
    // The root must be rejected before the initializer creates anything.
  } catch {
    Issue.record("Unexpected text runtime root error: \(error)")
  }

  do {
    _ = try AppleLocalAILEAPAudioRuntime(rootURL: linkedRoot)
    Issue.record("The audio runtime accepted a symbolic-link root.")
  } catch AppleLocalAILEAPError.invalidArtifactRoot {
    // The audio runtime shares the same admission boundary.
  } catch {
    Issue.record("Unexpected audio runtime root error: \(error)")
  }

  #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func artifactStorePreservesADirectoryAtTheDestinationPath() async throws {
  let fixture = try ArtifactFixture()
  try FileManager.default.createDirectory(
    at: fixture.destination, withIntermediateDirectories: false)

  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await fixture.prepare()
  }

  #expect(FileManager.default.fileExists(atPath: fixture.destination.path))
  #expect(
    (try FileManager.default.attributesOfItem(atPath: fixture.destination.path))[.type]
      as? FileAttributeType == .typeDirectory)
  #expect(fixture.transport.requests.isEmpty)
}

@Test func artifactStorePreservesADirectoryAtTheStagingPath() async throws {
  let fixture = try ArtifactFixture()
  try FileManager.default.createDirectory(at: fixture.staging, withIntermediateDirectories: false)

  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await fixture.prepare()
  }

  #expect(FileManager.default.fileExists(atPath: fixture.staging.path))
  #expect(
    (try FileManager.default.attributesOfItem(atPath: fixture.staging.path))[.type]
      as? FileAttributeType == .typeDirectory)
  #expect(fixture.transport.requests.isEmpty)
}

@Test func artifactStorePromotesCompleteStagingWithoutRefetching() async throws {
  let fixture = try ArtifactFixture()
  try fixture.contents.write(to: fixture.staging)

  #expect(try await fixture.prepare() == [fixture.destination])
  #expect(fixture.transport.requests.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
}

@Test func artifactStoreRefetchesCompleteButCorruptStaging() async throws {
  let fixture = try ArtifactFixture()
  try Data("broken".utf8).write(to: fixture.staging)

  _ = try await fixture.prepare()

  #expect(fixture.transport.requests.count == 1)
  #expect(fixture.transport.requests.first?.value(forHTTPHeaderField: "Range") == nil)
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
}

@Test func artifactStoreResumesTheExactAdvertisedRange() async throws {
  let fixture = try ArtifactFixture(replies: [
    .response(status: 206, headers: ["Content-Range": "bytes 3-5/6"], body: Data("def".utf8))
  ])
  try Data("abc".utf8).write(to: fixture.staging)

  _ = try await fixture.prepare()

  #expect(fixture.transport.requests.count == 1)
  #expect(fixture.transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=3-")
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
}

@Test func artifactStoreRestartsWhenTheServerIgnoresRange() async throws {
  let fixture = try ArtifactFixture()
  try Data("abc".utf8).write(to: fixture.staging)

  _ = try await fixture.prepare()

  #expect(fixture.transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=3-")
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
}

@Test(arguments: [
  [:],
  ["Content-Range": "bytes 2-5/6"],
  ["Content-Range": "bytes 3-4/6"],
  ["Content-Range": "bytes 3-5/7"],
  ["Content-Range": "bytes 3-5/*"],
  ["Content-Range": "items 3-5/6"],
  ["Content-Range": "bytes 3-5/6", "Content-Length": "2"],
])
func artifactStoreRejectsInvalidRangeMetadata(headers: [String: String]) async throws {
  let fixture = try ArtifactFixture(replies: [
    .response(status: 206, headers: headers, body: Data("def".utf8))
  ])
  try Data("abc".utf8).write(to: fixture.staging)

  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await fixture.prepare()
  }

  #expect(fixture.transport.requests.count == 3)
  #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
}

@Test func artifactStoreRetriesFromThePersistedPrefix() async throws {
  let fixture = try ArtifactFixture(replies: [
    // End a short response normally so URLSession delivers its bytes before
    // the store rejects the incomplete body and issues its range retry.
    .response(status: 200, headers: [:], body: Data("abc".utf8)),
    .response(status: 206, headers: ["Content-Range": "bytes 3-5/6"], body: Data("def".utf8)),
  ])

  _ = try await fixture.prepare()

  #expect(fixture.transport.requests.count == 2)
  #expect(fixture.transport.requests.first?.value(forHTTPHeaderField: "Range") == nil)
  #expect(fixture.transport.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=3-")
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
}

@Test func artifactStoreDoesNotPromoteAnOversizedResponse() async throws {
  let fixture = try ArtifactFixture(replies: [
    .response(status: 200, headers: [:], body: Data("abcdefg".utf8))
  ])

  await #expect(throws: AppleLocalAILEAPError.self) {
    _ = try await fixture.prepare()
  }

  #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
}

@Test func artifactStoreCancellationDoesNotDeleteValidCache() async throws {
  let fixture = try ArtifactFixture()
  try fixture.contents.write(to: fixture.destination)
  let cancelled = Task {
    try await fixture.prepare { progress in
      if progress.phase == .checking { withUnsafeCurrentTask { $0?.cancel() } }
    }
  }

  await #expect(throws: CancellationError.self) { try await cancelled.value }

  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
  #expect(fixture.transport.requests.isEmpty)
  #expect(try await fixture.prepare() == [fixture.destination])
}

@Test func artifactStoreCancellationBeforeVerificationDoesNotPromoteStaging() async throws {
  let fixture = try ArtifactFixture()
  try fixture.contents.write(to: fixture.staging)
  let cancelled = Task {
    try await fixture.prepare { progress in
      if progress.phase == .verifying { withUnsafeCurrentTask { $0?.cancel() } }
    }
  }

  await #expect(throws: CancellationError.self) { try await cancelled.value }

  #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
  #expect(fixture.transport.requests.isEmpty)
  #expect(try await fixture.prepare() == [fixture.destination])
}

@Test func artifactStoreRejectsConcurrentOwnersAndReleasesCancelledLease() async throws {
  let fixture = try ArtifactFixture(replies: [.hold])
  let first = Task { try await fixture.prepare() }
  defer { first.cancel() }
  try await fixture.transport.waitForRequest()

  do {
    _ = try await fixture.prepare()
    Issue.record("A second owner acquired the same artifact root.")
  } catch AppleLocalAILEAPError.modelBusy {
    // The independent caller must not touch the first owner's staging file.
  }
  #expect(fixture.transport.requests.count == 1)

  first.cancel()
  await #expect(throws: CancellationError.self) { try await first.value }
  fixture.transport.replaceReplies([
    .response(status: 200, headers: [:], body: fixture.contents)
  ])

  #expect(try await fixture.prepare() == [fixture.destination])
  #expect(try Data(contentsOf: fixture.destination) == fixture.contents)
}

@Test func artifactStoreReleasesLeaseAfterDownloadFailure() async throws {
  let fixture = try ArtifactFixture(replies: [
    .response(status: 503, headers: [:], body: Data())
  ])

  await #expect(throws: AppleLocalAILEAPError.self) { try await fixture.prepare() }
  fixture.transport.replaceReplies([
    .response(status: 200, headers: [:], body: fixture.contents)
  ])

  #expect(try await fixture.prepare() == [fixture.destination])
}

@Test func artifactStoreRejectsOverflowingArtifactTotals() async throws {
  let fixture = try ArtifactFixture()
  let files = [UInt64.max, 1].enumerated().map { index, count in
    LEAPArtifactFile(
      fileName: "part-\(index)", remoteURL: fixture.artifact.remoteURL,
      byteCount: count, sha256: fixture.artifact.sha256)
  }

  do {
    _ = try await LEAPArtifactStore.prepare(
      files: files, rootURL: fixture.root, minimumFreeBytes: 0, progress: nil)
    Issue.record("An overflowing artifact total was accepted.")
  } catch AppleLocalAILEAPError.insufficientDisk(let required, _) {
    #expect(required == UInt64.max)
  }
  #expect(fixture.transport.requests.isEmpty)
  #expect(try await fixture.prepare() == [fixture.destination])
}

private final class ArtifactFixture: @unchecked Sendable {
  let root: URL
  let artifact: LEAPArtifactFile
  let contents = Data("abcdef".utf8)
  let transport: ArtifactTransport

  var sessionConfiguration: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ArtifactURLProtocol.self]
    return configuration
  }

  var destination: URL { root.appendingPathComponent(artifact.fileName) }
  var staging: URL { root.appendingPathComponent(".\(artifact.fileName).download") }

  init(replies: [ArtifactReply]? = nil) throws {
    let identifier = UUID().uuidString.lowercased()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LEAPArtifactStore-\(identifier)", isDirectory: true)
    artifact = LEAPArtifactFile(
      fileName: "fixture.bundle",
      remoteURL: URL(string: "https://\(identifier).invalid/fixture.bundle")!,
      byteCount: UInt64(contents.count),
      sha256: SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined())
    transport = ArtifactTransport(
      replies: replies ?? [
        .response(status: 200, headers: [:], body: contents)
      ])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    ArtifactURLProtocol.registry.register(transport, for: artifact.remoteURL)
  }

  deinit {
    ArtifactURLProtocol.registry.unregister(artifact.remoteURL)
    try? FileManager.default.removeItem(at: root)
  }

  func prepare(
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)? = nil
  ) async throws -> [URL] {
    return try await LEAPArtifactStore.prepare(
      files: [artifact], rootURL: root, minimumFreeBytes: 0,
      progress: progress, sessionConfiguration: sessionConfiguration)
  }
}

private enum ArtifactReply: Sendable {
  case response(status: Int, headers: [String: String], body: Data)
  case hold
}

private final class ArtifactTransport: @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [ArtifactReply]
  private var recordedRequests: [URLRequest] = []
  private var replyIndex = 0

  init(replies: [ArtifactReply]) { self.replies = replies }

  var requests: [URLRequest] { lock.withLock { recordedRequests } }

  func reply(to request: URLRequest) -> ArtifactReply {
    lock.withLock {
      recordedRequests.append(request)
      let reply = replies[min(replyIndex, replies.count - 1)]
      replyIndex += 1
      return reply
    }
  }

  func replaceReplies(_ replies: [ArtifactReply]) {
    lock.withLock {
      self.replies = replies
      replyIndex = 0
    }
  }

  func waitForRequest() async throws {
    for _ in 0..<500 {
      if !requests.isEmpty { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw URLError(.timedOut)
  }
}

private final class ArtifactURLProtocol: URLProtocol, @unchecked Sendable {
  static let registry = Registry()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let transport = Self.registry.transport(for: url) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    switch transport.reply(to: request) {
    case .hold:
      break
    case .response(let status, let headers, let body):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [URL: ArtifactTransport] = [:]

    func register(_ transport: ArtifactTransport, for url: URL) {
      lock.withLock { transports[url] = transport }
    }

    func unregister(_ url: URL) {
      lock.withLock { _ = transports.removeValue(forKey: url) }
    }

    func transport(for url: URL) -> ArtifactTransport? {
      lock.withLock { transports[url] }
    }
  }
}
