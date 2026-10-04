/// Product-wide generation value policy shared by UI, wire decoding, and
/// Foundation Models adapters. These bounds mirror the Apple Foundation Models
/// contract so an accepted value can be forwarded without clamping or fallback.
package enum GenerationPolicy {
  package static let minimumTemperature = 0.0
  package static let maximumTemperature = 1.0
  package static let minimumProbabilityThreshold = 0.01
  package static let maximumProbabilityThreshold = 1.0

  package static func acceptsTemperature(_ value: Double) -> Bool {
    value.isFinite && (minimumTemperature...maximumTemperature).contains(value)
  }

  package static func acceptsProbabilityThreshold(_ value: Double) -> Bool {
    value.isFinite && (minimumProbabilityThreshold...maximumProbabilityThreshold).contains(value)
  }
}
