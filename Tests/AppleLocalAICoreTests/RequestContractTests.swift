import Testing
@testable import AppleLocalAICore

@Suite("Request contract")
struct RequestContractTests {
  @Test func trimsPrompt() throws {
    #expect(try NormalizedPrompt("  hello  ").value == "hello")
  }

  @Test func rejectsEmptyPrompt() {
    #expect(throws: PromptValidationError.empty) {
      _ = try NormalizedPrompt("  \n ")
    }
  }
}
