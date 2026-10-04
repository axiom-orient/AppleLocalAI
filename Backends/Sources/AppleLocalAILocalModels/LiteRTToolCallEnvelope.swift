import Foundation

/// Strict parsing of the existing prompt-driven tool envelope. No prose/fence
/// extraction: only a complete JSON envelope can authorize a native tool event.
package enum LiteRTToolCallEnvelope {
  package static func parse(_ text: String, allowedNames: Set<String>) throws
    -> (name: String, arguments: String)?
  {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    } catch {
      if text.contains("\"tool_call\"") { throw EnvelopeError.invalid }
      return nil
    }
    guard let object = value as? [String: Any], let raw = object["tool_call"] else { return nil }
    guard Set(object.keys) == ["tool_call"], let call = raw as? [String: Any],
      Set(call.keys) == ["name", "arguments"],
      let name = call["name"] as? String, allowedNames.contains(name),
      let arguments = call["arguments"] as? [String: Any]
    else { throw EnvelopeError.invalid }
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return (name, String(decoding: data, as: UTF8.self))
  }

  package enum EnvelopeError: Error, LocalizedError {
    case invalid
    package var errorDescription: String? {
      "Tool output must be one complete JSON envelope with a registered name and object arguments"
    }
  }
}
