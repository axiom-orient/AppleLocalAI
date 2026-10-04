import CryptoKit
import Darwin
import Foundation

struct LEAPArtifactFile: Hashable, Sendable {
  let fileName: String
  let remoteURL: URL
  let byteCount: UInt64
  let sha256: String
}

/// Exact, modality-neutral artifact acquisition. Native LEAP never sees a
/// partially downloaded file: every file is staged, sized, hashed, and moved
/// into its final path only after verification.
enum LEAPArtifactStore {
  static func prepare(
    files: [LEAPArtifactFile],
    rootURL: URL,
    minimumFreeBytes: UInt64,
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)?,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    capacityProvider: (@Sendable (URL) throws -> UInt64?)? = nil
  ) async throws -> [URL] {
    try Task.checkCancellation()
    guard !files.isEmpty else { return [] }
    try validateArtifactRoot(at: rootURL)
    try validateArtifactNames(files)
    // Keep the lock file in place: removing it would let another process lock
    // a different inode while this process still owns the original lease.
    let lease = try acquireLease(rootURL: rootURL)
    defer { _ = Darwin.close(lease) }
    try validateArtifactTotal(files)

    var paths: [URL] = []
    paths.reserveCapacity(files.count)
    for file in files {
      try Task.checkCancellation()
      let destination = rootURL.appending(path: file.fileName, directoryHint: .notDirectory)
      emit(
        progress,
        phase: .checking,
        bytes: 0,
        total: file.byteCount,
        file: file.fileName)

      if itemExists(at: destination) {
        do {
          try validate(file: destination, against: file)
          try Task.checkCancellation()
          emit(
            progress,
            phase: .ready,
            bytes: file.byteCount,
            total: file.byteCount,
            file: file.fileName)
          paths.append(destination)
          continue
        } catch let error as AppleLocalAILEAPError {
          guard isInvalidArtifact(error), isRemovableArtifact(at: destination) else {
            throw error
          }
          try Task.checkCancellation()
          try FileManager.default.removeItem(at: destination)
        }
      }

      // Keep one deterministic staging path per immutable artifact. This lets
      // a later process resume a partial HTTP response with a byte range while
      // keeping the final model path atomic and independently verifiable.
      let staging = rootURL.appending(
        path: ".\(file.fileName).download",
        directoryHint: .notDirectory)
      do {
        try Task.checkCancellation()
        var stagingVerified = false
        var attempt = 0
        while true {
          if itemExists(at: staging) {
            do {
              try ensureRegularFile(at: staging, expected: file)
            } catch let error as AppleLocalAILEAPError {
              guard isInvalidArtifact(error), isRemovableArtifact(at: staging) else {
                throw error
              }
              try Task.checkCancellation()
              try FileManager.default.removeItem(at: staging)
            }
          }
          if itemExists(at: staging), try byteCount(of: staging) == file.byteCount {
            emit(
              progress,
              phase: .verifying,
              bytes: file.byteCount,
              total: file.byteCount,
              file: file.fileName)
            do {
              try validate(file: staging, against: file)
              stagingVerified = true
              break
            } catch let error as AppleLocalAILEAPError {
              guard isInvalidArtifact(error), isRemovableArtifact(at: staging) else {
                throw error
              }
              try Task.checkCancellation()
              try FileManager.default.removeItem(at: staging)
            }
          }
          let stagedBytes = try byteCount(of: staging)
          let resumableBytes = stagedBytes < file.byteCount ? stagedBytes : 0
          // A verified destination or complete staging file returns above. At
          // this point only a network write can consume new space; moving the
          // completed staging file into place is an in-volume rename.
          try checkDiskCapacity(
            rootURL: rootURL,
            requiredArtifactBytes: file.byteCount - resumableBytes,
            minimumFreeBytes: minimumFreeBytes,
            capacityProvider: capacityProvider)
          do {
            try await download(
              file,
              to: staging,
              progress: progress,
              sessionConfiguration: sessionConfiguration)
            break
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            try Task.checkCancellation()
            // File write, flush, and close errors must escape immediately;
            // retrying could otherwise validate and promote an unflushed file.
            guard isRetryableDownloadError(error), attempt < 2 else { throw error }
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
          }
        }
        if !stagingVerified {
          let stagedBytes = try byteCount(of: staging)
          emit(
            progress,
            phase: .verifying,
            bytes: stagedBytes,
            total: file.byteCount,
            file: file.fileName)
          try validate(file: staging, against: file)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
        emit(
          progress,
          phase: .ready,
          bytes: file.byteCount,
          total: file.byteCount,
          file: file.fileName)
        paths.append(destination)
      } catch {
        let primary = error
        do {
          try removeManagedArtifact(at: staging)
        } catch {
          throw NSError(
            domain: "AppleLocalAI.LEAPArtifactStore", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "The partial model could not be removed after \(primary.localizedDescription): \(error.localizedDescription)",
              NSUnderlyingErrorKey: primary,
              NSMultipleUnderlyingErrorsKey: [primary as NSError, error as NSError],
            ])
        }
        throw primary
      }
    }
    try Task.checkCancellation()
    return paths
  }

  private static func acquireLease(rootURL: URL) throws -> Int32 {
    let lockURL = rootURL.appendingPathComponent(".artifact-store.lock")
    let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      _ = Darwin.close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN {
        throw AppleLocalAILEAPError.modelBusy
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return descriptor
  }

  static func validateArtifactRoot(at url: URL) throws {
    guard url.isFileURL else { throw AppleLocalAILEAPError.invalidArtifactRoot }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw AppleLocalAILEAPError.invalidArtifactRoot
    }
  }

  /// Validates a root before a runtime initializer creates it. A missing root
  /// is allowed; an existing symlink or special file is rejected before
  /// `createDirectory` can follow or mutate it.
  static func validateArtifactRootBeforeCreation(at url: URL) throws {
    guard url.isFileURL else { throw AppleLocalAILEAPError.invalidArtifactRoot }
    do {
      try validateArtifactRoot(at: url)
    } catch {
      let nsError = error as NSError
      let missing =
        nsError.domain == NSCocoaErrorDomain
        && (nsError.code == CocoaError.fileNoSuchFile.rawValue
          || nsError.code == CocoaError.fileReadNoSuchFile.rawValue)
      guard missing else { throw error }
    }
  }

  private static func validateArtifactTotal(_ files: [LEAPArtifactFile]) throws {
    var total: UInt64 = 0
    for file in files {
      let (next, overflow) = total.addingReportingOverflow(file.byteCount)
      guard !overflow else {
        throw AppleLocalAILEAPError.insufficientDisk(requiredBytes: .max, availableBytes: nil)
      }
      total = next
    }
  }

  private static func validateArtifactNames(_ files: [LEAPArtifactFile]) throws {
    var names = Set<String>()
    for file in files {
      let name = file.fileName
      guard !name.isEmpty, name != ".", name != "..",
        name.utf8.count <= 255,
        !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
        names.insert(name).inserted
      else {
        throw AppleLocalAILEAPError.invalidArtifact(
          expectedBytes: file.byteCount,
          actualBytes: 0,
          expectedSHA256: file.sha256,
          actualSHA256: "<invalid-file-name>")
      }
    }
  }

  private static func isRetryableDownloadError(_ error: Error) -> Bool {
    if let error = error as? AppleLocalAILEAPError,
      case .downloadFailed = error
    {
      return true
    }
    return (error as NSError).domain == NSURLErrorDomain
  }

  private static func isInvalidArtifact(_ error: AppleLocalAILEAPError) -> Bool {
    if case .invalidArtifact = error { return true }
    return false
  }

  private static func itemExists(at url: URL) -> Bool {
    itemType(at: url) != nil
  }

  private static func itemType(at url: URL) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type]
      as? FileAttributeType
  }

  private static func isRemovableArtifact(at url: URL) -> Bool {
    guard let type = itemType(at: url) else { return false }
    return type == .typeRegular || type == .typeSymbolicLink
  }

  private static func removeManagedArtifact(at url: URL) throws {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
      let failure = error as NSError
      if failure.domain == NSCocoaErrorDomain,
        failure.code == CocoaError.fileNoSuchFile.rawValue
          || failure.code == CocoaError.fileReadNoSuchFile.rawValue
      {
        return
      }
      throw error
    }
    guard let type = attributes[.type] as? FileAttributeType,
      type == .typeRegular || type == .typeSymbolicLink
    else { return }
    try FileManager.default.removeItem(at: url)
  }

  private static func ensureRegularFile(at url: URL, expected: LEAPArtifactFile) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw AppleLocalAILEAPError.invalidArtifact(
        expectedBytes: expected.byteCount,
        actualBytes: 0,
        expectedSHA256: expected.sha256,
        actualSHA256: "<non-regular-file>")
    }
  }

  private static func download(
    _ file: LEAPArtifactFile,
    to staging: URL,
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)?,
    sessionConfiguration: URLSessionConfiguration
  ) async throws {
    try Task.checkCancellation()
    let initialBytes = try byteCount(of: staging)
    emit(
      progress,
      phase: .downloading,
      bytes: initialBytes,
      total: file.byteCount,
      file: file.fileName)

    var request = URLRequest(
      url: file.remoteURL,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 60 * 60)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    if initialBytes > 0 && initialBytes < file.byteCount {
      request.setValue("bytes=\(initialBytes)-", forHTTPHeaderField: "Range")
    }

    let delegate = try LEAPStreamingDownloadDelegate(
      stagingURL: staging,
      initialBytes: initialBytes,
      expectedBytes: file.byteCount,
      progress: { bytes in
        emit(
          progress,
          phase: .downloading,
          bytes: bytes,
          total: file.byteCount,
          file: file.fileName)
      })
    let session = URLSession(
      configuration: sessionConfiguration,
      delegate: delegate,
      delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request)
    try await withTaskCancellationHandler {
      task.resume()
      try await delegate.wait()
      try Task.checkCancellation()
    } onCancel: {
      task.cancel()
    }
  }

  private static func byteCount(of url: URL) throws -> UInt64 {
    guard itemExists(at: url) else { return 0 }
    // URL resource values can remain cached after a long-lived FileHandle
    // appends to a staging file. Ask the open file descriptor for its current
    // end offset so resume validation cannot reject a complete file as stale.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.seekToEnd()
  }

  static func validate(file url: URL, against expected: LEAPArtifactFile) throws {
    try Task.checkCancellation()
    try validateArtifactRoot(at: url.deletingLastPathComponent())
    try ensureRegularFile(at: url, expected: expected)
    let actualBytes = try byteCount(of: url)
    let actualSHA256 = try sha256(of: url)
    try Task.checkCancellation()
    guard actualBytes == expected.byteCount, actualSHA256 == expected.sha256 else {
      throw AppleLocalAILEAPError.invalidArtifact(
        expectedBytes: expected.byteCount,
        actualBytes: actualBytes,
        expectedSHA256: expected.sha256,
        actualSHA256: actualSHA256)
    }
  }

  private static func checkDiskCapacity(
    rootURL: URL,
    requiredArtifactBytes: UInt64,
    minimumFreeBytes: UInt64,
    capacityProvider: (@Sendable (URL) throws -> UInt64?)?
  ) throws {
    let available: UInt64?
    if let capacityProvider {
      available = try capacityProvider(rootURL)
    } else {
      let values = try rootURL.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }
    // `requiredArtifactBytes` is the additional staging allocation, not a
    // second copy of an already verified destination.
    let (required, requiredOverflow) = requiredArtifactBytes.addingReportingOverflow(
      minimumFreeBytes)
    guard !requiredOverflow else {
      throw AppleLocalAILEAPError.insufficientDisk(
        requiredBytes: .max,
        availableBytes: available)
    }
    guard available.map({ $0 >= required }) ?? true else {
      throw AppleLocalAILEAPError.insufficientDisk(
        requiredBytes: requiredOverflow ? .max : required,
        availableBytes: available)
    }
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func emit(
    _ progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)?,
    phase: AppleLocalAILEAPDownloadProgress.Phase,
    bytes: UInt64,
    total: UInt64,
    file: String
  ) {
    progress?(
      AppleLocalAILEAPDownloadProgress(
        phase: phase,
        completedBytes: bytes,
        totalBytes: total,
        currentFile: file))
  }
}

/// Streams HTTP response bytes directly to the persistent staging file. The
/// delegate is deliberately private: it is transport mechanics, not part of
/// the LEAP or Foundation Models boundary.
private final class LEAPStreamingDownloadDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let stagingURL: URL
  private let initialBytes: UInt64
  private let expectedBytes: UInt64
  private let progress: @Sendable (UInt64) -> Void
  private let progressQuantum: UInt64 = 1 * 1024 * 1024
  private let lock = NSLock()
  private var fileHandle: FileHandle?
  private var totalBytes: UInt64
  private var lastReportedBytes: UInt64
  private var completion: Result<Void, Error>?
  private var continuation: CheckedContinuation<Void, Error>?
  private var statusCode: Int?

  init(
    stagingURL: URL,
    initialBytes: UInt64,
    expectedBytes: UInt64,
    progress: @escaping @Sendable (UInt64) -> Void
  ) throws {
    self.stagingURL = stagingURL
    self.initialBytes = initialBytes
    self.expectedBytes = expectedBytes
    self.totalBytes = initialBytes < expectedBytes ? initialBytes : 0
    self.lastReportedBytes = initialBytes < expectedBytes ? initialBytes : 0
    self.progress = progress
    super.init()

    if initialBytes == 0 || initialBytes >= expectedBytes {
      FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
      self.fileHandle = try FileHandle(forWritingTo: stagingURL)
      try self.fileHandle?.truncate(atOffset: 0)
    } else {
      self.fileHandle = try FileHandle(forWritingTo: stagingURL)
      try self.fileHandle?.seekToEnd()
    }
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let completion {
        lock.unlock()
        continuation.resume(with: completion)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse,
      http.statusCode == 200 || http.statusCode == 206
    else {
      finish(
        .failure(
          AppleLocalAILEAPError.downloadFailed(
            statusCode: (response as? HTTPURLResponse)?.statusCode)))
      completionHandler(.cancel)
      return
    }

    statusCode = http.statusCode
    if http.statusCode == 206 && !isValidRangeResponse(http) {
      finish(.failure(AppleLocalAILEAPError.downloadFailed(statusCode: http.statusCode)))
      completionHandler(.cancel)
      return
    }
    if initialBytes > 0 && http.statusCode == 200 {
      // The server ignored Range. Restart safely rather than appending a full
      // response to the old prefix.
      do {
        try fileHandle?.close()
        FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: stagingURL)
        try fileHandle?.truncate(atOffset: 0)
        totalBytes = 0
        lastReportedBytes = 0
        progress(0)
      } catch {
        finish(.failure(error))
        completionHandler(.cancel)
        return
      }
    }
    completionHandler(.allow)
  }

  private func isValidRangeResponse(_ response: HTTPURLResponse) -> Bool {
    guard initialBytes > 0, initialBytes < expectedBytes,
      let header = response.value(forHTTPHeaderField: "Content-Range")
    else { return false }
    let fields = header.split(whereSeparator: { $0.isWhitespace })
    guard fields.count == 2, fields[0].lowercased() == "bytes" else { return false }
    let rangeAndTotal = fields[1].split(separator: "/", omittingEmptySubsequences: false)
    guard rangeAndTotal.count == 2,
      let total = UInt64(rangeAndTotal[1]), total == expectedBytes
    else { return false }
    let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2,
      let start = UInt64(bounds[0]), start == initialBytes,
      let end = UInt64(bounds[1]), end == expectedBytes - 1,
      start <= end
    else { return false }
    let length = response.expectedContentLength
    return length < 0 || UInt64(length) == expectedBytes - initialBytes
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // URLSession's delegate queue is serial. Once finish closes the writer,
    // callbacks that were already queued must not mutate the staging file.
    guard let fileHandle else { return }
    do {
      let (total, overflow) = totalBytes.addingReportingOverflow(UInt64(data.count))
      guard !overflow, total <= expectedBytes else {
        finish(.failure(AppleLocalAILEAPError.downloadFailed(statusCode: statusCode)))
        dataTask.cancel()
        return
      }
      try fileHandle.write(contentsOf: data)
      totalBytes = total
      let shouldReport = total == expectedBytes || total - lastReportedBytes >= progressQuantum
      if shouldReport { lastReportedBytes = total }
      if shouldReport { progress(total) }
    } catch {
      finish(.failure(error))
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      if (error as NSError).code == NSURLErrorCancelled {
        finish(.failure(CancellationError()))
      } else {
        finish(.failure(error))
      }
      return
    }
    guard let statusCode, (200..<300).contains(statusCode), totalBytes == expectedBytes else {
      finish(.failure(AppleLocalAILEAPError.downloadFailed(statusCode: statusCode)))
      return
    }
    finish(.success(()))
  }

  private func finish(_ result: Result<Void, Error>) {
    // Flush and close before waking the awaiting task. Validation opens a
    // separate read handle; validating while this writer is still open can
    // observe stale file-size metadata on iOS's app container filesystem.
    lock.lock()
    guard completion == nil else {
      lock.unlock()
      return
    }
    var finalResult = result
    if let fileHandle {
      do {
        try fileHandle.synchronize()
      } catch {
        if case .success = finalResult { finalResult = .failure(error) }
      }
      do {
        try fileHandle.close()
      } catch {
        if case .success = finalResult { finalResult = .failure(error) }
      }
    }
    fileHandle = nil
    completion = finalResult
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: finalResult)
  }
}
