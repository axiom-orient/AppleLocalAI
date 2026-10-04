import Foundation

#if targetEnvironment(simulator)
  import Darwin
#endif

/// Developer-environment metadata only; never changes Apple's model availability.
struct SystemModelExecutionEnvironment: Sendable {
  let isSimulator: Bool
  let runtimeVersion: String
  let hostVersion: String?

  static var current: Self {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let runtime = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    #if targetEnvironment(simulator)
      return Self(isSimulator: true, runtimeVersion: runtime, hostVersion: readHostVersion())
    #else
      return Self(isSimulator: false, runtimeVersion: runtime, hostVersion: nil)
    #endif
  }

  var hasVersionMismatch: Bool {
    guard isSimulator, let hostVersion,
      let runtimeMajor = majorVersion(runtimeVersion), let hostMajor = majorVersion(hostVersion)
    else { return false }
    return runtimeMajor != hostMajor
  }

  var issue: String? {
    guard hasVersionMismatch, let hostVersion else { return nil }
    return
      "Simulator iOS \(runtimeVersion) · 호스트 macOS \(hostVersion). Apple 모델 추론을 직접 실행해 결과를 확인합니다."
  }

  private func majorVersion(_ value: String) -> Int? {
    value.split(separator: ".").first.flatMap { Int($0) }
  }

  #if targetEnvironment(simulator)
    private static func readHostVersion() -> String? {
      // Simulator and host share the Darwin kernel. This public, read-only key
      // returns the host product version, unlike ProcessInfo's runtime version.
      var count = 0
      guard sysctlbyname("kern.osproductversion", nil, &count, nil, 0) == 0,
        count > 0, count <= 128
      else { return nil }
      var buffer = [CChar](repeating: 0, count: count)
      let result = buffer.withUnsafeMutableBufferPointer { pointer in
        sysctlbyname("kern.osproductversion", pointer.baseAddress, &count, nil, 0)
      }
      guard result == 0 else { return nil }
      let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return String(bytes: bytes, encoding: .utf8)
    }
  #endif
}
