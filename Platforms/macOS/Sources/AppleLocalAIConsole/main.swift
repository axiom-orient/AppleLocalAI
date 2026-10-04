#if os(macOS)

  import AppleLocalAICore
  import AppleLocalAI
  import AppleLocalAIHost
  import AppleLocalAIFoundationModels
  import Darwin
  import Foundation
  import FoundationModels
  import FoundationModelsUtilities
  import ImageIO
  import Vision

  @MainActor
  @main
  struct AppleLocalAIConsole {
    static func main() async {
      do {
        try await run(arguments: Array(CommandLine.arguments.dropFirst()))
      } catch let error as ConsoleError {
        writeError(error.description)
        exit(error.exitCode)
      } catch {
        writeError("error: \(error)")
        exit(1)
      }
    }

    private static func run(arguments: [String]) async throws {
      switch arguments.first ?? "status" {
      case "status":
        try await printStatus()
      case "ask":
        try await ask(arguments: Array(arguments.dropFirst()))
      case "vision":
        try await vision(arguments: Array(arguments.dropFirst()))
      case "vision-tool":
        try await visionTool(arguments: Array(arguments.dropFirst()))
      case "structured":
        try await structured(arguments: Array(arguments.dropFirst()))
      case "dynamic":
        try await dynamic(arguments: Array(arguments.dropFirst()))
      case "pcc":
        try await runPCC(arguments: Array(arguments.dropFirst()))
      case "remote":
        try await runRemote(arguments: Array(arguments.dropFirst()))
      case "help", "--help", "-h":
        printHelp()
      default:
        throw ConsoleError.usage("unknown command '\(arguments[0])'")
      }
    }

    private static func printStatus() async throws {
      let plan = try LocalAIPlan(platform: .mac, workload: .nativeFeature)
      let model = SystemLanguageModel.default

      print("runtime=" + plan.runtime.rawValue)
      print("availability=" + availabilityDescription(model.availability))
      print("is_available=" + String(model.isAvailable))
      print("request_readiness=" + AppleLocalAIModelReadiness.evaluate(model).rawValue)
      print("context_size=" + String(model.contextSize))
      print("supported_language_count=" + String(model.supportedLanguages.count))
      print("supports_current_locale=" + String(model.supportsLocale()))
      print("variant=" + model.variant.displayName)
      print("capability_vision=" + String(model.capabilities.contains(.vision)))
      print(
        "capability_guided_generation=" + String(model.capabilities.contains(.guidedGeneration)))
      print("capability_reasoning=" + String(model.capabilities.contains(.reasoning)))
      print("capability_tool_calling=" + String(model.capabilities.contains(.toolCalling)))

      let privateCloud = PrivateCloudComputeLanguageModel()
      print("pcc_availability=" + pccAvailabilityDescription(privateCloud.availability))
      print("pcc_quota_limit_reached=" + String(privateCloud.quotaUsage.isLimitReached))
      if case .available = privateCloud.availability {
        print("pcc_context_size=" + String(try await privateCloud.contextSize))
        print(
          "pcc_supported_language_count=" + String(try await privateCloud.supportedLanguages.count))
        print("pcc_supports_current_locale=" + String(try await privateCloud.supportsLocale()))
      }
    }

    private static func ask(arguments: [String]) async throws {
      let prompt = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !prompt.isEmpty else {
        throw ConsoleError.usage("ask requires a non-empty prompt")
      }

      let model = try availableSystemModel()

      let session = try makeSession(model: model, instructions: LocalAIInstructions.system)
      let response = try await session.respond(try AppleLocalAIRequest(text: prompt))
      print(response.content)
    }

    private static func vision(arguments: [String]) async throws {
      let url = try imageURL(arguments: arguments, command: "vision")

      let model = try availableSystemModel(requiring: .vision)

      let text = arguments.dropFirst().joined(separator: " ").trimmingCharacters(
        in: .whitespacesAndNewlines)
      let promptText = text.isEmpty ? "이 이미지를 분석해줘." : text
      let textInput = try AppleLocalAITextInput(promptText)
      let imageInput = try AppleLocalAIImageInput(url: url, label: "console-image")
      let request = try AppleLocalAIVisionRequest(text: textInput, image: imageInput).makeRequest()
      let session = try makeSession(model: model, instructions: LocalAIInstructions.system)
      let response = try await session.respond(request)
      print(response.content)
    }

    private static func visionTool(arguments: [String]) async throws {
      let url = try imageURL(arguments: arguments, command: "vision-tool")

      let model = try availableSystemModel(requiring: .toolCalling)
      guard model.capabilities.contains(.vision) else {
        throw ConsoleError.unsupported("Foundation Models vision readiness is unavailable")
      }

      let promptText = arguments.dropFirst().joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let attachmentLabel = "console-image"
      let requestText =
        promptText.isEmpty
        ? "Use OCRTool to transcribe every piece of text in the attached image."
        : promptText
      let labeledRequestText =
        "\(requestText) The exact attachment label is \"\(attachmentLabel)\". Use that label for the OCRTool image argument."
      let textInput = try AppleLocalAITextInput(labeledRequestText)
      let imageInput = try AppleLocalAIImageInput(url: url, label: attachmentLabel)
      let request = try AppleLocalAIVisionRequest(text: textInput, image: imageInput).makeRequest()
      let tools = AppleLocalAITools.vision(ocr: true, barcode: false, imageMetadata: false)
      let session = try makeSession(
        model: model,
        instructions: LocalAIInstructions.system,
        tools: tools,
        toolCallingMode: .allowed
      )
      let response = try await session.respond(request)
      let toolCallCount = session.history.reduce(into: 0) { count, entry in
        if case .toolCalls(let calls) = entry {
          count += calls.count
        }
      }
      print("tool_calls=" + String(toolCallCount))
      print(response.content)
    }

    private static func structured(arguments: [String]) async throws {
      let prompt = try nonEmptyPrompt(arguments, command: "structured")
      let model = try availableSystemModel(requiring: .guidedGeneration)
      let session = try makeSession(model: model, instructions: LocalAIInstructions.system)
      let request = AppleLocalAIRequest(prompt: prompt)
      var result: FoundationModelsStructuredResponse?
      _ = try await session.streamGenerated(
        request, generating: FoundationModelsStructuredResponse.self
      ) { snapshot in result = snapshot.content }
      guard let result else { throw ConsoleError.unsupported("structured response was empty") }
      print(result.summary)
      if !result.keyPoints.isEmpty {
        print("key_points=" + result.keyPoints.joined(separator: " | "))
      }
      if !result.nextActions.isEmpty {
        print("next_actions=" + result.nextActions.joined(separator: " | "))
      }
    }

    private static func dynamic(arguments: [String]) async throws {
      let prompt = try nonEmptyPrompt(arguments, command: "dynamic")
      let model = try availableSystemModel(requiring: .guidedGeneration)
      let session = try makeSession(model: model, instructions: LocalAIInstructions.system)
      let schema = try FoundationModelsResponseSchema.dynamic()
      let request = AppleLocalAIRequest(prompt: prompt)
      var result: GeneratedContent?
      _ = try await session.stream(request, schema: schema) { snapshot in result = snapshot.content
      }
      guard let result, result.isComplete else {
        throw ConsoleError.unsupported("dynamic response was incomplete")
      }
      print(result.jsonString)
    }

    private static func runPCC(arguments: [String]) async throws {
      switch arguments.first ?? "status" {
      case "status":
        try await printPCCStatus()
      case "ask":
        let prompt = try nonEmptyPrompt(Array(arguments.dropFirst()), command: "pcc ask")
        let model = PrivateCloudComputeLanguageModel()
        guard case .available = model.availability else {
          throw ConsoleError.modelUnavailable(pccAvailabilityDescription(model.availability))
        }
        guard !model.quotaUsage.isLimitReached else {
          throw ConsoleError.modelUnavailable("pcc quota limit reached")
        }
        guard try await model.supportsLocale() else {
          throw ConsoleError.unsupported(
            "Private Cloud Compute does not support the current locale")
        }
        let session = try makeSession(model: model, instructions: LocalAIInstructions.system)
        let response = try await session.respond(AppleLocalAIRequest(prompt: prompt))
        print(response.content)
      case "help", "--help", "-h":
        printPCCHelp()
      default:
        throw ConsoleError.usage("unknown PCC command '" + (arguments.first ?? "") + "'")
      }
    }

    private static func printPCCStatus() async throws {
      let model = PrivateCloudComputeLanguageModel()
      print("availability=" + pccAvailabilityDescription(model.availability))
      print("quota_limit_reached=" + String(model.quotaUsage.isLimitReached))
      if let resetDate = model.quotaUsage.resetDate {
        print("quota_reset=" + resetDate.formatted(date: .abbreviated, time: .shortened))
      }
      if case .available = model.availability {
        print("context_size=" + String(try await model.contextSize))
        print("supported_language_count=" + String(try await model.supportedLanguages.count))
        print("supports_current_locale=" + String(try await model.supportsLocale()))
      }
    }

    private static func availableSystemModel(
      requiring capability: LanguageModelCapabilities.Capability? = nil
    ) throws -> SystemLanguageModel {
      let model = SystemLanguageModel.default
      let readiness = AppleLocalAIModelReadiness.evaluate(model)
      guard readiness == .ready else {
        throw ConsoleError.modelUnavailable("request_readiness=" + readiness.rawValue)
      }
      if let capability, !model.capabilities.contains(capability) {
        throw ConsoleError.unsupported("requested Foundation Models capability is unavailable")
      }
      return model
    }

    private static func nonEmptyPrompt(_ arguments: [String], command: String) throws -> Prompt {
      let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        throw ConsoleError.usage(command + " requires a non-empty prompt")
      }
      return Prompt(text)
    }

    private static func imageURL(arguments: [String], command: String) throws -> URL {
      guard let path = arguments.first, !path.isEmpty else {
        throw ConsoleError.usage(command + " requires an image path and optional prompt")
      }
      let url = URL(fileURLWithPath: path)
      guard url.isFileURL,
        FileManager.default.isReadableFile(atPath: url.path),
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
      else {
        throw ConsoleError.usage("not a readable image: " + url.path)
      }
      return url
    }

    private static func runRemote(arguments: [String]) async throws {
      switch arguments.first ?? "status" {
      case "status":
        try printRemoteStatus()
      case "ask":
        try await askRemote(arguments: Array(arguments.dropFirst()))
      case "chat":
        try await chatRemote()
      case "help", "--help", "-h":
        printRemoteHelp()
      default:
        throw ConsoleError.usage("unknown remote command '\(arguments[0])'")
      }
    }

    private static func printRemoteStatus() throws {
      let configuration = try remoteConfiguration()
      print("runtime=foundation_models_remote_language_model")
      print("endpoint=\(configuration.endpoint.absoluteString)")
      print("model=\(configuration.modelName)")
      print("transport=apple_foundation_models_utilities")
      let authentication = (try remoteAPIKey()).isEmpty ? "none" : "bearer"
      print("authentication=" + authentication)
    }

    private static func askRemote(arguments: [String]) async throws {
      let prompt = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !prompt.isEmpty else {
        throw ConsoleError.usage("remote ask requires a non-empty prompt")
      }
      let session = try makeRemoteSession()
      let response = try await session.respond(try AppleLocalAIRequest(text: prompt))
      print(response.content)
    }

    private static func chatRemote() async throws {
      let session = try makeRemoteSession()
      print("Remote Foundation Models chat. Type /exit to finish.")
      while let line = readLine() {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt == "/exit" || prompt == "/quit" { break }
        guard !prompt.isEmpty else { continue }
        let response = try await session.respond(try AppleLocalAIRequest(text: prompt))
        print("assistant> \(response.content)")
      }
    }

    private static func makeRemoteSession() throws -> AppleLocalAISession {
      let configuration = try remoteConfiguration()
      let key = try remoteAPIKey()
      let headers = key.isEmpty ? [:] : ["Authorization": "Bearer " + key]
      let model = LocalLanguageModels.chatCompletions(
        name: configuration.modelName,
        baseURL: configuration.endpoint,
        headers: headers,
        supportsGuidedGeneration: false
      )
      return try makeSession(
        model: model,
        instructions: LocalAIInstructions.remote(modelName: configuration.modelName)
      )
    }

    private static func makeSession(
      model: any LanguageModel,
      instructions: String,
      tools: [any Tool] = [],
      toolCallingMode: GenerationOptions.ToolCallingMode? = nil
    ) throws -> AppleLocalAISession {
      let profile = try AppleLocalAIProfile(
        model: model,
        instructions: instructions,
        tools: tools,
        toolCallingMode: toolCallingMode
      )
      return AppleLocalAISession(profile: profile)
    }

    private static func remoteConfiguration() throws -> RemoteLanguageModelConfiguration {
      let environment = ProcessInfo.processInfo.environment
      guard let endpoint = environment[RemoteLanguageModelConfiguration.endpointEnvironmentKey],
        let modelName = environment[RemoteLanguageModelConfiguration.modelEnvironmentKey]
      else {
        throw ConsoleError.usage(
          "Set APPLELOCALAI_REMOTE_URL and APPLELOCALAI_REMOTE_MODEL before using remote commands")
      }
      do {
        return try RemoteLanguageModelConfiguration(
          endpointString: endpoint, modelName: modelName)
      } catch let error as RemoteLanguageModelConfigurationError {
        throw ConsoleError.usage(error.localizedDescription)
      }
    }

    private static func remoteAPIKey() throws -> String {
      do {
        return try RemoteCredentialPolicy.normalized(
          ProcessInfo.processInfo.environment[RemoteLanguageModelConfiguration.apiKeyEnvironmentKey]
        ) ?? ""
      } catch {
        throw ConsoleError.usage(error.localizedDescription)
      }
    }

    private static func availabilityDescription(
      _ availability: SystemLanguageModel.Availability
    ) -> String {
      switch availability {
      case .available:
        return "available"
      case .unavailable(.deviceNotEligible):
        return "unavailable: device_not_eligible"
      case .unavailable(.appleIntelligenceNotEnabled):
        return "unavailable: apple_intelligence_not_enabled"
      case .unavailable(.modelNotReady):
        return "unavailable: model_not_ready"
      case .unavailable:
        return "unavailable: unknown"
      }
    }

    private static func printHelp() {
      print(
        """
        AppleLocalAIConsole — macOS 27 Foundation Models probe

        Usage:
          AppleLocalAIConsole status
          AppleLocalAIConsole ask <prompt>
          AppleLocalAIConsole vision <image-path> [prompt]
          AppleLocalAIConsole vision-tool <image-path> [prompt]
          AppleLocalAIConsole structured <prompt>
          AppleLocalAIConsole dynamic <prompt>
          AppleLocalAIConsole pcc status
          AppleLocalAIConsole pcc ask <prompt>
          AppleLocalAIConsole remote status
          AppleLocalAIConsole remote ask <prompt>
          AppleLocalAIConsole remote chat

        Remote commands require APPLELOCALAI_REMOTE_URL and APPLELOCALAI_REMOTE_MODEL.
        APPLELOCALAI_REMOTE_API_KEY is optional and is sent as a Bearer token when present.
        """
      )
    }

    private static func printRemoteHelp() {
      print(
        """
        Remote commands:
          AppleLocalAIConsole remote status
          AppleLocalAIConsole remote ask <prompt>
          AppleLocalAIConsole remote chat

        Configure APPLELOCALAI_REMOTE_URL / APPLELOCALAI_REMOTE_MODEL and optionally
        APPLELOCALAI_REMOTE_API_KEY. 'chat' keeps one LanguageModelSession for multiple turns.
        """
      )
    }

    private static func printPCCHelp() {
      print(
        """
        Private Cloud Compute commands:
          AppleLocalAIConsole pcc status
          AppleLocalAIConsole pcc ask <prompt>

        PCC is explicit and never an automatic fallback for the system model.
        """
      )
    }

    private static func pccAvailabilityDescription(
      _ availability: PrivateCloudComputeLanguageModel.Availability
    ) -> String {
      switch availability {
      case .available:
        return "available"
      case .unavailable(.deviceNotEligible):
        return "unavailable: device_not_eligible"
      case .unavailable(.systemNotReady):
        return "unavailable: system_not_ready"
      case .unavailable:
        return "unavailable: unknown"
      }
    }

    private static func writeError(_ message: String) {
      let output = message.hasSuffix("\n") ? message : "\(message)\n"
      FileHandle.standardError.write(Data(output.utf8))
    }
  }

  private enum ConsoleError: Error, CustomStringConvertible {
    case usage(String)
    case modelUnavailable(String)
    case unsupported(String)

    var description: String {
      switch self {
      case .usage(let message):
        return "usage error: \(message)\nRun 'AppleLocalAIConsole help' for usage."
      case .modelUnavailable(let availability):
        return "system language model is not available (\(availability))"
      case .unsupported(let message):
        return message
      }
    }

    var exitCode: Int32 {
      switch self {
      case .usage:
        return 64
      case .modelUnavailable:
        return 69
      case .unsupported:
        return 69
      }
    }
  }

#else
  #error("This executable requires macOS 27 or later.")
#endif
