import Testing

@testable import AppleLocalAICore

@Suite("Model readiness")
struct ModelReadinessTests {
  @Test("Availability has priority over context and locale")
  func unavailable() {
    #expect(
      AppleLocalAIModelReadiness.evaluate(
        isAvailable: false, contextSize: 0, supportsLocale: false) == .unavailable)
  }

  @Test("A non-positive context never admits a request", arguments: [-1, 0])
  func contextUnavailable(_ contextSize: Int) {
    #expect(
      AppleLocalAIModelReadiness.evaluate(
        isAvailable: true, contextSize: contextSize, supportsLocale: true) == .contextUnavailable)
  }

  @Test("The requested locale must be supported")
  func unsupportedLocale() {
    #expect(
      AppleLocalAIModelReadiness.evaluate(
        isAvailable: true, contextSize: 4096, supportsLocale: false) == .unsupportedLocale)
  }

  @Test("All preflight conditions must hold")
  func ready() {
    #expect(
      AppleLocalAIModelReadiness.evaluate(
        isAvailable: true, contextSize: 4096, supportsLocale: true) == .ready)
  }
}
