#if os(macOS)
  import AppleLocalAIWire
  import Foundation
  import FoundationModels

  /// Descriptions of client-owned tools. No filesystem, shell or network execution
  /// exists in the provider. AppleLocalAI's handoff policy transfers the call
  /// before dispatch.
  struct ClientOwnedTool: Tool, Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    func call(arguments: GeneratedContent) async throws -> String {
      throw WireError(
        status: 500, code: "tool_authority_violation",
        message: "Client-owned tools must never execute in the provider")
    }
  }

  /// Single request-to-native schema translation boundary, before backend effects.
  /// The accepted subset is explicit; unsupported constraints are never dropped.
  struct NativeRequestSchemas {
    static let maximumSchemaDepth = 32
    static let maximumSchemaNodes = 4_096

    let tools: [any Tool]
    let toolNames: Set<String>
    let response: GenerationSchema?

    init(request: InferenceRequest) throws {
      let selected: [WireTool]
      switch request.toolChoice {
      case .none: selected = []
      case .named(let name): selected = request.tools.filter { $0.name == name }
      case .auto, .required: selected = request.tools
      }
      toolNames = Set(selected.map(\.name))
      tools = try selected.enumerated().map { index, tool in
        do {
          return ClientOwnedTool(
            name: tool.name, description: tool.description,
            parameters: try Self.generationSchema(from: tool.schema, name: "tool_\(index)"))
        } catch {
          throw WireError.unsupported(
            "Tool \(tool.name) uses an unsupported JSON Schema: \(error.localizedDescription)")
        }
      }
      if let schema = request.schema {
        do {
          response = try Self.generationSchema(from: schema, name: "response")
        } catch {
          throw WireError.unsupported(
            "Unsupported response JSON Schema: \(error.localizedDescription)")
        }
      } else {
        response = nil
      }
    }

    /// Convert the supported JSON Schema subset into Apple's dynamic schema
    /// representation. This is a request-boundary translation, not a second
    /// schema owner: validation and output decoding remain Foundation Models'
    /// responsibility. Unsupported constraints fail before model execution.
    private static func generationSchema(from schema: JSONValue, name: String) throws
      -> GenerationSchema
    {
      var remainingNodes = maximumSchemaNodes
      let converted = try dynamicSchema(
        from: schema, name: name, depth: 0, remainingNodes: &remainingNodes)
      guard !converted.allowsNull else {
        throw ToolSchemaError.unsupported("the root schema cannot be null")
      }
      return try GenerationSchema(root: converted.value, dependencies: [])
    }

    private static func dynamicSchema(
      from schema: JSONValue, name: String, depth: Int, remainingNodes: inout Int
    ) throws -> (value: DynamicGenerationSchema, allowsNull: Bool) {
      guard depth <= maximumSchemaDepth, remainingNodes > 0 else {
        throw ToolSchemaError.unsupported("JSON Schema exceeds the translation depth/node budget")
      }
      remainingNodes -= 1
      guard let object = schema.object else {
        throw ToolSchemaError.invalid("schema must be an object")
      }
      try validateStringMetadata(object)

      if let anyOf = object["anyOf"] {
        try validateKeys(object, allowed: ["anyOf", "description", "title", "$schema", "$comment"])
        guard let choices = anyOf.array, !choices.isEmpty else {
          throw ToolSchemaError.invalid("anyOf must contain at least one schema")
        }
        guard choices.count <= remainingNodes else {
          throw ToolSchemaError.unsupported(
            "JSON Schema exceeds the depth/node translation budget")
        }
        // Every branch is translated, including null: no ignored sibling constraints.
        let converted = try choices.enumerated().map { index, choice in
          try dynamicSchema(
            from: choice, name: name + "_choice_\(index)", depth: depth + 1,
            remainingNodes: &remainingNodes)
        }
        let nullIndices = choices.indices.filter { choices[$0]["type"] == .string("null") }
        if !nullIndices.isEmpty {
          let nonNullIndices = choices.indices.filter { !nullIndices.contains($0) }
          guard nullIndices.count == 1, nonNullIndices.count == 1,
            let index = nonNullIndices.first, !converted[index].allowsNull
          else {
            throw ToolSchemaError.unsupported(
              "anyOf may contain null plus exactly one non-null schema")
          }
          return (
            DynamicGenerationSchema(
              name: name, anyOf: [converted[index].value, .null]), true
          )
        }
        guard converted.allSatisfy({ !$0.allowsNull }) else {
          throw ToolSchemaError.unsupported("nullable anyOf choices are not supported")
        }
        return (DynamicGenerationSchema(name: name, anyOf: converted.map(\.value)), false)
      }

      let type: String
      var allowsNull = false
      if let typeValue = object["type"] {
        if let explicit = typeValue.string {
          type = explicit
        } else if let choices = typeValue.array {
          guard choices.count <= Self.maximumSchemaNodes else {
            throw ToolSchemaError.unsupported(
              "JSON Schema exceeds the depth/node translation budget")
          }
          let names = try choices.map { value -> String in
            guard let name = value.string else {
              throw ToolSchemaError.invalid("type array must contain strings")
            }
            return name
          }
          allowsNull = names.contains("null")
          let nonNull = names.filter { $0 != "null" }
          guard nonNull.count == 1, Set(names).count == names.count else {
            throw ToolSchemaError.unsupported(
              "type arrays may contain null plus exactly one non-null type")
          }
          type = nonNull[0]
        } else {
          throw ToolSchemaError.invalid("type must be a string or an array of strings")
        }
      } else if object["properties"] != nil {
        type = "object"
      } else {
        throw ToolSchemaError.invalid("schema is missing type")
      }

      switch type {
      case "null":
        try validateKeys(object, allowed: ["type", "description", "title", "$schema", "$comment"])
        return (.null, true)

      case "string":
        try validateKeys(object, allowed: ["type", "description", "title", "$schema", "$comment"])
        return (
          nullableValue(
            DynamicGenerationSchema(type: String.self), name: name, allowsNull: allowsNull),
          allowsNull
        )

      case "integer":
        try validateKeys(object, allowed: ["type", "description", "title", "$schema", "$comment"])
        return (
          nullableValue(
            DynamicGenerationSchema(type: Int.self), name: name, allowsNull: allowsNull),
          allowsNull
        )

      case "number":
        try validateKeys(object, allowed: ["type", "description", "title", "$schema", "$comment"])
        return (
          nullableValue(
            DynamicGenerationSchema(type: Double.self), name: name, allowsNull: allowsNull),
          allowsNull
        )

      case "boolean":
        try validateKeys(object, allowed: ["type", "description", "title", "$schema", "$comment"])
        return (
          nullableValue(
            DynamicGenerationSchema(type: Bool.self), name: name, allowsNull: allowsNull),
          allowsNull
        )

      case "array":
        try validateKeys(
          object,
          allowed: [
            "type", "description", "title", "$schema", "$comment", "items", "minItems",
            "maxItems",
          ])
        guard let items = object["items"] else {
          throw ToolSchemaError.invalid("array schema is missing items")
        }
        let item = try dynamicSchema(
          from: items, name: name + "_item", depth: depth + 1, remainingNodes: &remainingNodes)
        guard !item.allowsNull else {
          throw ToolSchemaError.unsupported("nullable array items are not supported")
        }
        let minimum = try nonNegativeInt(object["minItems"], key: "minItems")
        let maximum = try nonNegativeInt(object["maxItems"], key: "maxItems")
        if let minimum, let maximum, minimum > maximum {
          throw ToolSchemaError.invalid("minItems must not exceed maxItems")
        }
        return (
          nullableValue(
            DynamicGenerationSchema(
              arrayOf: item.value, minimumElements: minimum, maximumElements: maximum),
            name: name, allowsNull: allowsNull),
          allowsNull
        )

      case "object":
        try validateKeys(
          object,
          allowed: [
            "type", "description", "title", "$schema", "$comment", "properties", "required",
            "additionalProperties",
          ])
        // Apple's property-list schema encodes a closed object. JSON Schema
        // omission permits extra keys, so accepting it would narrow the request.
        guard object["additionalProperties"] == .bool(false) else {
          throw ToolSchemaError.unsupported(
            "object schemas require explicit additionalProperties: false; open objects are unsupported"
          )
        }
        let properties: [String: JSONValue]
        if let value = object["properties"] {
          guard let parsed = value.object else {
            throw ToolSchemaError.invalid("properties must be an object")
          }
          properties = parsed
        } else {
          properties = [:]
        }
        guard properties.count <= remainingNodes else {
          throw ToolSchemaError.unsupported(
            "JSON Schema exceeds the depth/node translation budget")
        }
        let required = try requiredNames(object["required"], maximumCount: properties.count)
        guard required.isSubset(of: Set(properties.keys)) else {
          throw ToolSchemaError.invalid("required contains an unknown property")
        }
        let fields = try properties.keys.sorted().enumerated().map { index, key in
          guard let property = properties[key] else {
            throw ToolSchemaError.invalid("properties contains an unreadable key \(key)")
          }
          let converted = try dynamicSchema(
            from: property, name: name + "_property_\(index)", depth: depth + 1,
            remainingNodes: &remainingNodes)
          return DynamicGenerationSchema.Property(
            name: key,
            description: property["description"]?.string,
            schema: converted.value,
            isOptional: !required.contains(key)
          )
        }
        return (
          nullableValue(
            DynamicGenerationSchema(
              name: allowsNull ? name + "_value" : name,
              description: object["description"]?.string, properties: fields),
            name: name, allowsNull: allowsNull),
          allowsNull
        )

      default:
        throw ToolSchemaError.unsupported("JSON Schema type \(type) is not supported")
      }
    }

    private static func requiredNames(_ value: JSONValue?, maximumCount: Int) throws -> Set<String>
    {
      guard let value else { return [] }
      guard let names = value.array, names.allSatisfy({ $0.string != nil }) else {
        throw ToolSchemaError.invalid("required must be an array of strings")
      }
      guard names.count <= maximumCount else {
        throw ToolSchemaError.unsupported(
          "JSON Schema exceeds the depth/node translation budget")
      }
      let values = names.compactMap(\.string)
      guard Set(values).count == values.count else {
        throw ToolSchemaError.invalid("required must not contain duplicate property names")
      }
      return Set(values)
    }

    private static func nonNegativeInt(_ value: JSONValue?, key: String) throws -> Int? {
      guard let value else { return nil }
      guard let number = value.integer, number >= 0 else {
        throw ToolSchemaError.invalid("\(key) must be a nonnegative integer")
      }
      return number
    }

    private static func validateKeys(_ object: [String: JSONValue], allowed: Set<String>) throws {
      let unknown = Set(object.keys).subtracting(allowed)
      guard unknown.isEmpty else {
        throw ToolSchemaError.unsupported(
          "unsupported JSON Schema keywords: \(unknown.sorted().joined(separator: ", "))")
      }
    }

    private static func validateStringMetadata(_ object: [String: JSONValue]) throws {
      for key in ["description", "title", "$schema", "$comment"] {
        if let value = object[key], value.string == nil {
          throw ToolSchemaError.invalid("\(key) must be a string")
        }
      }
    }

    private static func nullableValue(
      _ value: DynamicGenerationSchema, name: String, allowsNull: Bool
    ) -> DynamicGenerationSchema {
      guard allowsNull else { return value }
      return DynamicGenerationSchema(name: name, anyOf: [value, .null])
    }

    private enum ToolSchemaError: Error, LocalizedError {
      case invalid(String)
      case unsupported(String)

      var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .unsupported(let message): return message
        }
      }
    }

  }
#endif
