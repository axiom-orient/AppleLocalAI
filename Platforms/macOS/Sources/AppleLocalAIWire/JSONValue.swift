import Foundation

/// Wire values, never model/session state. Numbers remain JSON numbers, not token estimates.
package enum JSONValue: Codable, Equatable, Sendable {
  package static let maximumNestingDepth = 64

  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case signedInteger(Int64)
  case unsignedInteger(UInt64)
  case bool(Bool)
  case null

  package init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    guard decoder.codingPath.count <= Self.maximumNestingDepth else {
      throw DecodingError.dataCorruptedError(
        in: value, debugDescription: "JSON exceeds the maximum nesting depth")
    }
    if value.decodeNil() {
      self = .null
    } else if let b = try? value.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? value.decode(Int64.self) {
      self =
        (-9_007_199_254_740_992...9_007_199_254_740_992).contains(n)
        ? .number(Double(n)) : .signedInteger(n)
    } else if let n = try? value.decode(UInt64.self) {
      self = .unsignedInteger(n)
    } else if let n = try? value.decode(Double.self), n.isFinite {
      guard abs(n) <= 9_007_199_254_740_992 || n.rounded() != n else {
        throw DecodingError.dataCorruptedError(
          in: value, debugDescription: "Integer outside exact 64-bit wire range")
      }
      self = .number(n)
    } else if let s = try? value.decode(String.self) {
      self = .string(s)
    } else if let a = try? value.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try value.decode([String: JSONValue].self))
    }
  }
  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let v): try container.encode(v)
    case .array(let v): try container.encode(v)
    case .string(let v): try container.encode(v)
    case .number(let v): try container.encode(v)
    case .signedInteger(let v): try container.encode(v)
    case .unsignedInteger(let v): try container.encode(v)
    case .bool(let v): try container.encode(v)
    case .null: try container.encodeNil()
    }
  }
  package subscript(_ key: String) -> JSONValue? { object?[key] }
  package var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
  package var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
  package var string: String? { if case .string(let v) = self { v } else { nil } }
  package var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
  package var number: Double? { if case .number(let v) = self { v } else { nil } }
  package var integer: Int? {
    if case .signedInteger(let n) = self { return Int(exactly: n) }
    if case .unsignedInteger(let n) = self { return Int(exactly: n) }
    guard let n = number, n.isFinite, n.rounded() == n,
      n >= Double(Int.min), n < Double(Int.max)
    else { return nil }
    return Int(n)
  }
  package func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
  package func jsonString() throws -> String { String(decoding: try encoded(), as: UTF8.self) }
  package func requiredString(_ key: String) throws -> String {
    guard let value = self[key]?.string else { throw WireError.invalid("Expected string: \(key)") }
    return value
  }
  package func allowingOnly(_ keys: Set<String>) throws {
    guard let values = object else { throw WireError.invalid("Expected JSON object") }
    let unknown = Set(values.keys).subtracting(keys)
    guard unknown.isEmpty else {
      throw WireError.unsupported("Unsupported fields: \(unknown.sorted().joined(separator: ", "))")
    }
  }
}

package struct WireError: Error, LocalizedError, Equatable, Sendable {
  package let status: Int
  package let code: String
  package let message: String
  package var errorDescription: String? { message }
  package init(status: Int, code: String, message: String) {
    self.status = status
    self.code = code
    self.message = message
  }
  package static func invalid(_ message: String) -> Self {
    .init(status: 400, code: "invalid_request_error", message: message)
  }
  package static func unsupported(_ message: String) -> Self {
    .init(status: 422, code: "unsupported_capability", message: message)
  }
  package static func unavailable(_ message: String) -> Self {
    .init(status: 503, code: "model_unavailable", message: message)
  }
  package var json: JSONValue {
    .object([
      "type": .string("error"),
      "error": .object(["type": .string(code), "message": .string(message)]),
    ])
  }
}
