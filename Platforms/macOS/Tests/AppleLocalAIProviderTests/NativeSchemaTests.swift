#if os(macOS)
  @testable import AppleLocalAIWire
  import Foundation
  import Testing
  @testable import AppleLocalAIProvider

  /// Native schema construction only. Does not qualify any model or generation.
  @Suite struct NativeSchemaTests {
    private func request(schema: String) throws -> InferenceRequest {
      var request = try InferenceRequest.decode(
        api: .responses, data: Data(#"{"model":"probe","input":"answer"}"#.utf8))
      request.schema = try JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8))
      return request
    }

    @Test(arguments: [
      #"{"type":"object"}"#,
      #"{"type":"object","additionalProperties":true}"#,
      #"{"type":"object","additionalProperties":{"type":"string"}}"#,
      #"{"type":"object","properties":{"value":{"type":"string"}}}"#,
      #"{"type":"object","properties":{"nested":{"type":"object"}},"additionalProperties":false}"#,
      #"{"type":"array","items":{"type":"object"}}"#,
      #"{"anyOf":[{"type":"string"},{"type":"object"}]}"#,
    ]) func openObjectsAreRejectedForResponsesAndTools(_ schema: String) throws {
      let responseRequest = try request(schema: schema)
      var toolRequest = responseRequest
      toolRequest.schema = nil
      toolRequest.tools = [
        WireTool(
          name: "lookup", description: "Lookup", schema: try #require(responseRequest.schema))
      ]
      for request in [responseRequest, toolRequest] {
        do {
          _ = try NativeRequestSchemas(request: request)
          Issue.record("An open object schema must not silently become a closed object")
        } catch let error as WireError {
          #expect(error.status == 422)
          #expect(error.message.contains("additionalProperties"))
        }
      }
    }

    @Test func explicitlyClosedEmptyAndNestedObjectsPreserveNativeEncoding() throws {
      let request = try request(
        schema:
          #"{"type":"object","properties":{"nested":{"type":"object","additionalProperties":false}},"required":["nested"],"additionalProperties":false}"#
      )
      let prepared = try NativeRequestSchemas(request: request)
      let response = try #require(prepared.response)
      let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
      #expect(encoded["additionalProperties"] == .bool(false))
      let definitions = try #require(encoded["$defs"]?.object)
      let nested = try #require(definitions.values.first)
      #expect(nested["additionalProperties"] == .bool(false))
      #expect(nested["properties"] == .object([:]))
    }

    @Test func disabledToolsDoNotRequireNativeSchemaTranslation() throws {
      var request = try request(schema: #"{"type":"object"}"#)
      request.tools = [
        WireTool(name: "unused", description: "Unused", schema: try #require(request.schema))
      ]
      request.schema = nil
      request.toolChoice = .none
      #expect(try NativeRequestSchemas(request: request).tools.isEmpty)
    }

    @Test(arguments: [
      #"{"anyOf":[{"type":"string"},{"type":"integer"}],"minLength":2}"#,
      #"{"anyOf":[{"type":"string"},{"type":"integer"}],"enum":["only"]}"#,
      #"{"type":"object","properties":{"a":{"anyOf":[{"type":"string"},{"type":"null","enum":[null]}]}},"additionalProperties":false}"#,
      ##"{"anyOf":[{"type":"string"},{"type":"integer"}],"$ref":"#/$defs/other"}"##,
    ]) func anyOfConstraintsAreNeverDiscarded(_ schema: String) throws {
      let request = try request(schema: schema)
      #expect(throws: (any Error).self) { try NativeRequestSchemas(request: request) }
    }

    @Test func optionalNullableAndDistinctPropertyPathsRemainSupported() throws {
      let request = try request(
        schema:
          #"{"type":"object","properties":{"a-b":{"type":"object","properties":{"x":{"type":"string"}},"additionalProperties":false},"a_b":{"type":"object","properties":{"y":{"type":"integer"}},"additionalProperties":false},"optional":{"anyOf":[{"type":"string"},{"type":"null"}]}},"additionalProperties":false}"#
      )
      let prepared = try NativeRequestSchemas(request: request)
      #expect(prepared.response != nil)
    }

    @Test func nullablePropertiesPreserveExplicitNullInNativeSchema() throws {
      let request = try request(
        schema:
          #"{"type":"object","properties":{"requiredNullable":{"type":["string","null"]},"requiredObjectNullable":{"type":["object","null"],"properties":{"value":{"type":"string"}},"additionalProperties":false},"optionalNullable":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["requiredNullable","requiredObjectNullable"],"additionalProperties":false}"#
      )
      let prepared = try NativeRequestSchemas(request: request)
      guard let response = prepared.response else {
        Issue.record("Expected a translated response schema")
        return
      }
      let encoded = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(response))
      #expect(
        encoded["required"]?.array == [
          .string("requiredNullable"), .string("requiredObjectNullable"),
        ])
      #expect(containsExplicitNull(encoded))
      #expect(containsObjectProperty(encoded, named: "value"))
    }

    @Test func depthAndNodeBudgetsFailClosed() throws {
      var request = try request(schema: #"{"type":"string"}"#)
      var schema = JSONValue.object(["type": .string("string")])
      for _ in 0...NativeRequestSchemas.maximumSchemaDepth {
        schema = .object(["type": .string("array"), "items": schema])
      }
      request.schema = schema
      #expect(throws: (any Error).self) { try NativeRequestSchemas(request: request) }
      let fields = Dictionary(
        uniqueKeysWithValues: (0..<NativeRequestSchemas.maximumSchemaNodes).map { index in
          ("f\(index)", JSONValue.object(["type": .string("string")]))
        })
      request.schema = .object([
        "type": .string("object"), "properties": .object(fields),
        "additionalProperties": .bool(false),
      ])
      #expect(throws: (any Error).self) { try NativeRequestSchemas(request: request) }
    }

    @Test func branchAndRequiredCollectionBudgetsFailBeforeExpansion() throws {
      var request = try request(schema: #"{"type":"string"}"#)
      let choices = (0...NativeRequestSchemas.maximumSchemaNodes).map { _ in
        JSONValue.object(["type": .string("string")])
      }
      request.schema = .object(["anyOf": .array(choices)])
      #expect(throws: (any Error).self) { try NativeRequestSchemas(request: request) }

      let required = (0...NativeRequestSchemas.maximumSchemaNodes).map {
        JSONValue.string("field-\($0)")
      }
      request.schema = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array(required),
        "additionalProperties": .bool(false),
      ])
      #expect(throws: (any Error).self) { try NativeRequestSchemas(request: request) }
    }

    private func containsExplicitNull(_ value: JSONValue) -> Bool {
      if value["type"] == .string("null") { return true }
      if let object = value.object, object.values.contains(where: containsExplicitNull) {
        return true
      }
      return value.array?.contains(where: containsExplicitNull) == true
    }

    private func containsObjectProperty(_ value: JSONValue, named name: String) -> Bool {
      if value["properties"]?.object?[name] != nil { return true }
      if let object = value.object,
        object.values.contains(where: { containsObjectProperty($0, named: name) })
      {
        return true
      }
      return value.array?.contains { containsObjectProperty($0, named: name) } == true
    }
  }
#endif
