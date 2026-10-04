import FoundationModels
import Testing

@testable import AppleLocalAILocalModels

@Test func rejectsTopKOutsideTheNativeIntegerRange() {
  for value in [0, -1, Int(Int32.max) + 1, Int.max] {
    #expect(throws: LiteRTFMError.self) {
      _ = try LiteRTSampler.make(.init(samplingMode: .random(top: value)))
    }
  }
}

@Test func preservesValidTopKAndGreedySampling() throws {
  for value in [1, Int(Int32.max)] {
    let sampler = try #require(try LiteRTSampler.make(.init(samplingMode: .random(top: value))))
    #expect(sampler.topK == value)
  }
  let greedy = try #require(try LiteRTSampler.make(.init(samplingMode: .greedy, temperature: 0.8)))
  #expect(greedy.topK == 1)
  #expect(greedy.temperature == 0)
}

@Test func rejectsUnrepresentableOrNonFiniteTemperature() {
  for value in [
    Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.leastNonzeroMagnitude,
  ] {
    #expect(throws: LiteRTFMError.self) {
      _ = try LiteRTSampler.make(.init(temperature: value))
    }
  }
}

@Test func validatesProbabilityBeforeLossyFloatConversion() throws {
  for value in [Double.nan, .infinity, -.infinity, 1.nextUp, -Double.leastNonzeroMagnitude] {
    #expect(throws: LiteRTFMError.self) {
      _ = try LiteRTSampler.make(.init(samplingMode: .random(probabilityThreshold: value)))
    }
  }
  for value in [0.0, 1.0] {
    let sampler = try #require(
      try LiteRTSampler.make(.init(samplingMode: .random(probabilityThreshold: value))))
    #expect(sampler.topP == Float(value))
  }
}

@Test func rejectsUnmappedSamplingSeeds() {
  for mode in [
    GenerationOptions.SamplingMode.random(top: 40, seed: 7),
    .random(probabilityThreshold: 0.9, seed: 7),
  ] {
    #expect(throws: LiteRTFMError.self) {
      _ = try LiteRTSampler.make(.init(samplingMode: mode))
    }
  }
}
