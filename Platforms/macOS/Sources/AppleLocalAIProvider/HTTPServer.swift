#if os(macOS)
  import AppleLocalAI
  import AppleLocalAIHost
  import AppleLocalAIWire
  import Foundation
  import NIOCore
  import NIOHTTP1
  import NIOPosix
  import OSLog

  private typealias HTTPConnection = NIOAsyncChannel<
    HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>
  >
  private typealias HTTPWriter = NIOAsyncChannelOutboundWriter<
    HTTPPart<HTTPResponseHead, ByteBuffer>
  >

  private actor ConnectionAdmission {
    private var count = 0
    func enter() -> Bool {
      guard count < ProviderConfiguration.maximumConnections else { return false }
      count += 1
      return true
    }
    func leave() { count -= 1 }
  }

  /// HTTP parsing/framing/backpressure belong to Apple's SwiftNIO. This executable
  /// adds only authentication, admission and the external protocol translation.
  struct ProviderHTTPServer: Sendable {
    let configuration: ProviderConfiguration
    let token: String
    let provider: NativeProvider
    private let admission = ConnectionAdmission()
    private let logger = Logger(subsystem: "com.applelocalai.provider", category: "transport")

    init(configuration: ProviderConfiguration, token: String, provider: NativeProvider) {
      self.configuration = configuration
      self.token = token
      self.provider = provider
    }

    func run() async throws {
      let listener: NIOAsyncChannel<HTTPConnection, Never> = try await ServerBootstrap(
        group: MultiThreadedEventLoopGroup.singleton
      )
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
      .bind(host: "127.0.0.1", port: configuration.port) { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withPipeliningAssistance: false)
          try channel.pipeline.syncOperations.addHandler(
            ProviderHTTPByteBufferResponsePartHandler())
          return try HTTPConnection(wrappingChannelSynchronously: channel)
        }
      }
      print(
        "AppleLocalAIProvider listening on 127.0.0.1:\(configuration.port); authentication required. Native inference is not pre-qualified by startup."
      )
      try await withThrowingDiscardingTaskGroup { group in
        try await listener.executeThenClose { inbound in
          for try await connection in inbound {
            guard await admission.enter() else {
              do { try await connection.channel.close().get() } catch {
                logger.error("Rejected connection close failed")
              }
              continue
            }
            group.addTask {
              await handle(connection)
              await admission.leave()
            }
          }
        }
      }
    }

    private func handle(_ connection: HTTPConnection) async {
      do {
        try await connection.executeThenClose { inbound, outbound in
          let reply = HTTPReply(writer: outbound)
          let reader = Task { try await receive(inbound) }
          let readDeadline = Task {
            try await Task.sleep(for: .seconds(ProviderConfiguration.headerTimeoutSeconds))
            reader.cancel()
            try await connection.channel.close().get()
          }
          let head: HTTPRequestHead
          let body: Data
          do {
            (head, body) = try await withTaskCancellationHandler(
              operation: { try await reader.value }, onCancel: { reader.cancel() })
            readDeadline.cancel()
          } catch {
            readDeadline.cancel()
            reader.cancel()
            try await reply.fail(asWireError(error))
            return
          }
          let route =
            head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? head.uri
          if head.method == .GET {
            switch route {
            case "/health":
              try await reply.json(
                .object(["status": .string("ok"), "scope": .string("transport-only")]), status: 200)
            case "/v1/models":
              let data: [JSONValue] = configuration.profiles.map {
                .object([
                  "id": .string($0.id), "object": .string("model"), "type": .string("model"),
                  "display_name": .string($0.id),
                  "owned_by": .string("AppleLocalAI"),
                  "metadata": .object([
                    "backend": .string($0.backend.rawValue),
                    "readiness": .string("configured-not-probed"),
                  ]),
                ])
              }
              try await reply.json(
                .object([
                  "object": .string("list"), "data": .array(data), "has_more": .bool(false),
                  "first_id": data.first?["id"] ?? .null, "last_id": data.last?["id"] ?? .null,
                ]), status: 200)
            default:
              try await reply.fail(
                WireError(status: 404, code: "not_found", message: "Unknown route"))
            }
            return
          }
          if route == "/v1/messages/count_tokens" {
            // A sum of independently tokenized strings is NOT the serialized model
            // input count. Do not return a fabricated count for unsupported models.
            try await reply.fail(
              WireError(
                status: 501, code: "not_implemented",
                message:
                  "Standalone Messages token counting is not qualified. Generation reports native measured usage."
              ))
            return
          }
          do {
            let request = try InferenceRequest.decode(api: WireAPI(path: route), data: body)
            await reply.configure(request)
            let generation = Task {
              try await provider.perform(request) { content, usage in
                if request.stream { try await reply.snapshot(content, usage: usage) }
              }
            }
            // TCP closure and request deadline cancel the actual native task. A
            // non-cooperative backend keeps admission occupied until it really exits.
            connection.channel.closeFuture.whenComplete { _ in generation.cancel() }
            let deadline = Task {
              try await Task.sleep(for: .seconds(ProviderConfiguration.requestTimeoutSeconds))
              generation.cancel()
              try await connection.channel.close().get()
            }
            defer { deadline.cancel() }
            let result = try await withTaskCancellationHandler(
              operation: { try await generation.value }, onCancel: { generation.cancel() })
            try await reply.complete(result, streaming: request.stream)
          } catch {
            logger.error("Request failed: \(String(reflecting: type(of: error)), privacy: .public)")
            try await reply.fail(asWireError(error))
          }
        }
      } catch {
        // No success marker after write failure, disconnect or timeout. This log
        // does not include prompts, tool arguments, credentials or model output.
        logger.error(
          "Connection terminated: \(String(reflecting: type(of: error)), privacy: .public)")
      }
    }

    private func receive(_ inbound: NIOAsyncChannelInboundStream<HTTPServerRequestPart>)
      async throws -> (HTTPRequestHead, Data)
    {
      var head: HTTPRequestHead?
      var body = Data()
      for try await part in inbound {
        try Task.checkCancellation()
        switch part {
        case .head(let value):
          guard head == nil else { throw WireError.invalid("Pipelined requests are not supported") }
          try authorize(value)
          let contentLengths = value.headers["content-length"]
          guard contentLengths.count <= 1 else {
            throw WireError.invalid("Multiple Content-Length headers are not supported")
          }
          let transferEncodings = value.headers["transfer-encoding"]
          guard
            transferEncodings.isEmpty
              || (transferEncodings.count == 1 && transferEncodings[0].lowercased() == "chunked")
          else {
            throw WireError.unsupported(
              "Only one chunked Transfer-Encoding is supported")
          }
          guard contentLengths.isEmpty || transferEncodings.isEmpty else {
            throw WireError.invalid(
              "Content-Length and Transfer-Encoding cannot be used together")
          }
          if let raw = contentLengths.first {
            guard let length = Int(raw), length >= 0,
              length <= ProviderConfiguration.maximumBodyBytes
            else {
              throw WireError(
                status: 413, code: "request_too_large", message: "Body size exceeds limit")
            }
          }
          head = value
        case .body(var bytes):
          guard head != nil else { throw WireError.invalid("Body without request head") }
          guard bytes.readableBytes <= ProviderConfiguration.maximumBodyBytes - body.count else {
            throw WireError(
              status: 413, code: "request_too_large", message: "Body size exceeds limit")
          }
          guard let chunk = bytes.readBytes(length: bytes.readableBytes) else {
            throw WireError.invalid("HTTP body buffer was not readable")
          }
          body.append(contentsOf: chunk)
        case .end(let trailers):
          guard let head, trailers == nil || trailers?.isEmpty == true else {
            throw WireError.invalid("Missing head or unsupported request trailers")
          }
          return (head, body)
        }
      }
      throw CancellationError()
    }

    private func authorize(_ head: HTTPRequestHead) throws {
      guard head.version.major == 1, head.version.minor == 1 else {
        throw WireError(
          status: 505, code: "unsupported_http_version", message: "HTTP/1.1 is required")
      }
      guard [.GET, .POST].contains(head.method) else {
        throw WireError(
          status: 405, code: "method_not_allowed", message: "Only GET and POST are supported")
      }
      guard head.headers["origin"].isEmpty else {
        throw WireError(
          status: 403, code: "browser_access_denied",
          message: "Browser-origin requests are not allowed")
      }
      let hosts = head.headers["host"]
      guard hosts.count == 1,
        ["127.0.0.1:\(configuration.port)", "localhost:\(configuration.port)"].contains(
          hosts[0].lowercased())
      else {
        throw WireError(status: 403, code: "invalid_host", message: "Invalid loopback Host header")
      }
      let bearer = head.headers["authorization"]
      let apiKey = head.headers["x-api-key"]
      let supplied: String
      if bearer.count == 1, apiKey.isEmpty, bearer[0].hasPrefix("Bearer ") {
        supplied = String(bearer[0].dropFirst(7))
      } else if apiKey.count == 1, bearer.isEmpty {
        supplied = apiKey[0]
      } else {
        throw WireError(
          status: 401, code: "authentication_error",
          message: "Provide exactly one Bearer token or x-api-key")
      }
      guard supplied.utf8.count <= ProviderConfiguration.maximumTokenBytes,
        ProviderConfiguration.tokensEqual(token, supplied)
      else {
        throw WireError(
          status: 401, code: "authentication_error", message: "Invalid local provider credential")
      }
      if head.method == .POST {
        let types = head.headers["content-type"]
        guard types.count == 1,
          types[0].split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            == "application/json"
        else {
          throw WireError(
            status: 415, code: "unsupported_media_type", message: "application/json is required")
        }
        guard head.headers["content-encoding"].isEmpty else {
          throw WireError.unsupported("Compressed request bodies are not supported")
        }
      }
    }
  }

  private actor HTTPReply {
    let writer: HTTPWriter
    private var output: WireOutput?
    private var headersSent = false
    private var ended = false
    init(writer: HTTPWriter) { self.writer = writer }
    func configure(_ request: InferenceRequest) {
      output = WireOutput(api: request.api, model: request.model)
    }
    func snapshot(_ content: String, usage: TokenUsage?) async throws {
      guard var output else { throw WireError.invalid("Response not configured") }
      let frames = try output.snapshot(content, usage: usage)
      self.output = output
      try await send(frames)
    }
    func complete(_ result: InferenceResult, streaming: Bool) async throws {
      guard var output else { throw WireError.invalid("Response not configured") }
      if streaming {
        let frames = try output.complete(result)
        self.output = output
        try await send(frames)
        try await finish()
      } else {
        try await json(output.response(result), status: 200)
      }
    }
    func fail(_ error: WireError) async throws {
      guard !ended else { return }
      if headersSent, var output {
        let frames = try output.failure(error)
        self.output = output
        try await send(frames)
        try await finish()
      } else {
        try await json(error.json, status: error.status)
      }
    }
    func json(_ value: JSONValue, status: Int) async throws {
      guard !headersSent, !ended else { throw WireError.invalid("Response already committed") }
      let body = try value.encoded()
      var headers = baseHeaders
      headers.add(name: "content-type", value: "application/json; charset=utf-8")
      headers.add(name: "content-length", value: String(body.count))
      headersSent = true
      try await writer.write(
        .head(
          .init(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
        ))
      try await writer.write(.body(ByteBuffer(bytes: body)))
      try await finish()
    }
    private var baseHeaders: HTTPHeaders {
      HTTPHeaders([
        ("connection", "close"), ("cache-control", "no-store"),
        ("x-content-type-options", "nosniff"),
      ])
    }
    private func send(_ frames: [Data]) async throws {
      guard !frames.isEmpty else { return }
      guard !ended else { throw WireError.invalid("Response already ended") }
      if !headersSent {
        var headers = baseHeaders
        headers.add(name: "content-type", value: "text/event-stream; charset=utf-8")
        headers.add(name: "transfer-encoding", value: "chunked")
        headersSent = true
        try await writer.write(.head(.init(version: .http1_1, status: .ok, headers: headers)))
      }
      for frame in frames { try await writer.write(.body(ByteBuffer(bytes: frame))) }
    }
    private func finish() async throws {
      guard !ended else { return }
      ended = true
      try await writer.write(.end(nil))
    }
  }

  func asWireError(_ error: any Error) -> WireError {
    if let error = error as? WireError { return error }
    let isSessionCancellation: Bool
    if let error = error as? AppleLocalAIError {
      if case .cancelled = error {
        isSessionCancellation = true
      } else {
        isSessionCancellation = false
      }
    } else {
      isSessionCancellation = false
    }
    if error is CancellationError || isSessionCancellation {
      return .init(
        status: 499, code: "request_cancelled",
        message: "Request cancelled; no completed result is available")
    }
    if error is ModelSelectionError {
      return .unavailable("No configured model satisfies this request and its consent policy")
    }
    if error is DecodingError {
      return .unsupported("Input schema could not be decoded by Foundation Models")
    }
    return .init(
      status: 502, code: "native_generation_failed",
      message:
        "Native model failed (\(String(reflecting: type(of: error)))); no fallback was attempted")
  }

  /// `NIOAsyncChannel` uses `ByteBuffer` for response bodies while the HTTP/1
  /// encoder consumes `IOData`. SwiftNIO's equivalent handler is internal to
  /// its WebSocket server target, so the provider owns this narrow adapter at
  /// the transport boundary.
  private final class ProviderHTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
      let part = Self.unwrapOutboundIn(data)
      switch part {
      case .head(let head):
        context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
      case .body(let buffer):
        context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
      case .end(let trailers):
        context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
      }
    }
  }
#endif
