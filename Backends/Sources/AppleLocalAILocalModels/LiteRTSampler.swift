// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Parts of this implementation were originally authored by @john-rocky and
// ported from https://github.com/john-rocky/swift-litert-lm/tree/main.

#if canImport(FoundationModels) && compiler(>=6.4)

  import FoundationModels
  @preconcurrency import LiteRTLM

  enum LiteRTSampler {
    static func make(_ options: GenerationOptions) throws -> SamplerConfig? {
      var topK = LiteRTDefaults.topK
      var topP = LiteRTDefaults.topP
      let requestedTemperature = options.temperature ?? LiteRTDefaults.temperature
      guard requestedTemperature.isFinite, requestedTemperature >= 0,
        Float(requestedTemperature).isFinite
      else {
        throw LiteRTFMError.unsupported(
          "temperature must be finite, nonnegative and representable by LiteRT")
      }
      var temperature = Float(requestedTemperature)

      if let kind = options.samplingMode?.kind {
        switch kind {
        case .greedy:
          topK = 1
          temperature = 0.0
        case .randomTopK(let k, let seed):
          guard seed == nil else {
            throw LiteRTFMError.unsupported("The LiteRT bridge does not map a random seed")
          }
          guard (1...Int(Int32.max)).contains(k) else {
            throw LiteRTFMError.unsupported("topK is outside LiteRT's positive Int32 range")
          }
          topK = k
        case .randomProbabilityThreshold(let threshold, let seed):
          guard seed == nil else {
            throw LiteRTFMError.unsupported("The LiteRT bridge does not map a random seed")
          }
          guard threshold.isFinite, (0...1).contains(threshold) else {
            throw LiteRTFMError.unsupported(
              "The probability threshold must be finite and between 0 and 1")
          }
          topP = Float(threshold)
        @unknown default:
          throw LiteRTFMError.unsupported("Unsupported native transcript entry or sampling mode")
        }
      }
      return try SamplerConfig(topK: topK, topP: topP, temperature: temperature)
    }
  }

#endif
