import AVFoundation
import Foundation
@preconcurrency import LeapSDK

/// The LEAP audio model bundle. The three files are pinned together because
/// the audio model, multimodal projector, and vocoder must be version-matched.
@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAPAudioModelID: String, CaseIterable, Hashable, Sendable {
  // Preserve the public artifact identifier and its encoded raw value.
  // swift-format-ignore: AlwaysUseLowerCamelCase
  case lfm2_5_audio_1_5B_q4_0

  public static let recommended: Self = .lfm2_5_audio_1_5B_q4_0

  public var repositoryID: String {
    "LiquidAI/LFM2.5-Audio-1.5B-GGUF-LEAP"
  }

  public var revision: String {
    "d78ca1db4adae8be7a7dbab003d128abdb5b94c6"
  }

  public var displayName: String { "LFM2.5 Audio 1.5B Q4_0" }
  public var quantization: String { "Q4_0" }

  public var requiredBytes: UInt64 {
    695_750_880 + 219_511_136 + 148_508_512
  }

  var artifactFiles: [LEAPArtifactFile] {
    [
      artifact(
        name: "LFM2.5-Audio-1.5B-Q4_0.gguf",
        bytes: 695_750_880,
        sha256: "3583bee853be20331ca342b0593fefd8acc43fb61a41ec6f1a1dc7465823e0d8"),
      artifact(
        name: "mmproj-LFM2.5-Audio-1.5B-Q4_0.gguf",
        bytes: 219_511_136,
        sha256: "222ebe9c595d78d2e75881e2427580edd93f5544d5bd875a29677f63687d7148"),
      artifact(
        name: "vocoder-LFM2.5-Audio-1.5B-Q4_0.gguf",
        bytes: 148_508_512,
        sha256: "7383a3c0af64ad10cfebf50eb88bc72b826dca79b0bd59c7fd65b0d6c904b0a7"),
    ]
  }

  private func artifact(name: String, bytes: UInt64, sha256: String) -> LEAPArtifactFile {
    LEAPArtifactFile(
      fileName: name,
      remoteURL: URL(string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(name)")!,
      byteCount: bytes,
      sha256: sha256)
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPPreparedAudioModel: Hashable, Sendable {
  public let model: AppleLocalAILEAPAudioModelID
  public let directoryURL: URL

  fileprivate init(model: AppleLocalAILEAPAudioModelID, directoryURL: URL) {
    self.model = model
    self.directoryURL = directoryURL
  }
}

/// Validated mono PCM input at the boundary between AVFAudio and LEAP.
@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPAudioInput: Hashable, Sendable {
  public static let maximumSeconds = 60

  public let samples: [Float]
  public let sampleRate: Int

  public init(samples: [Float], sampleRate: Int) throws {
    guard (8_000...96_000).contains(sampleRate),
      !samples.isEmpty,
      samples.count <= sampleRate * Self.maximumSeconds,
      samples.allSatisfy({ $0.isFinite && (-1...1).contains($0) })
    else {
      throw AppleLocalAILEAPError.invalidAudioInput(
        "Audio must be finite mono PCM in [-1, 1], 8–96 kHz, and at most 60 seconds.")
    }
    self.samples = samples
    self.sampleRate = sampleRate
  }

  /// AVAudioEngine normally supplies non-interleaved Float32 buffers. The
  /// adapter downmixes all channels to mono before passing samples to LEAP.
  public init(pcmBuffer: AVAudioPCMBuffer) throws {
    guard let channelData = pcmBuffer.floatChannelData else {
      throw AppleLocalAILEAPError.invalidAudioInput(
        "The AVAudioPCMBuffer must expose Float32 channel data.")
    }
    let frameCount = Int(pcmBuffer.frameLength)
    let channelCount = Int(pcmBuffer.format.channelCount)
    let rate = pcmBuffer.format.sampleRate
    guard rate.isFinite, (8_000...96_000).contains(rate),
      rate.rounded() == rate, frameCount > 0, channelCount > 0,
      frameCount <= Int(rate) * Self.maximumSeconds
    else {
      throw AppleLocalAILEAPError.invalidAudioInput(
        "The AVAudioPCMBuffer must contain at most 60 seconds at an integral 8–96 kHz sample rate.")
    }

    var mixed = [Double](repeating: 0, count: frameCount)
    let interleaved = pcmBuffer.format.isInterleaved
    for channel in 0..<channelCount {
      // Interleaved Float32 has one buffer containing all channel samples.
      let source = channelData[interleaved ? 0 : channel]
      for index in 0..<frameCount {
        let value = source[interleaved ? index * channelCount + channel : index]
        guard value.isFinite, (-1...1).contains(value) else {
          throw AppleLocalAILEAPError.invalidAudioInput(
            "Every PCM channel must contain finite samples in [-1, 1].")
        }
        mixed[index] += Double(value)
      }
    }
    let mono = mixed.map { Float($0 / Double(channelCount)) }
    try self.init(samples: mono, sampleRate: Int(rate))
  }
}

@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAPAudioVoice: String, CaseIterable, Hashable, Sendable {
  case usMale
  case usFemale
  case ukMale
  case ukFemale

  fileprivate var systemPrompt: String {
    switch self {
    case .usMale: "Perform TTS. Use the US male voice."
    case .usFemale: "Perform TTS. Use the US female voice."
    case .ukMale: "Perform TTS. Use the UK male voice."
    case .ukFemale: "Perform TTS. Use the UK female voice."
    }
  }
}

@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAPAudioRequest: Hashable, Sendable {
  case transcribe(audio: AppleLocalAILEAPAudioInput)
  case synthesize(text: String, voice: AppleLocalAILEAPAudioVoice)
  case speechToSpeech(audio: AppleLocalAILEAPAudioInput)
}

@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPAudioSamples: Hashable, Sendable {
  public let samples: [Float]
  public let sampleRate: Int

  init(samples: [Float], sampleRate: Int) throws {
    guard sampleRate > 0, !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
      throw AppleLocalAILEAPError.invalidAudioOutput(
        "LEAP returned an empty or non-finite PCM response.")
    }
    self.samples = samples
    self.sampleRate = sampleRate
  }

  public func makePCMBuffer() throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(sampleRate),
        channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)),
      let destination = buffer.floatChannelData?.pointee
    else {
      throw AppleLocalAILEAPError.invalidAudioOutput(
        "AVFAudio could not create a mono Float32 playback buffer.")
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let copied = samples.withUnsafeBufferPointer { source -> Bool in
      guard let baseAddress = source.baseAddress else { return false }
      destination.update(from: baseAddress, count: source.count)
      return true
    }
    guard copied else {
      throw AppleLocalAILEAPError.invalidAudioOutput(
        "The validated PCM response did not expose a readable sample buffer.")
    }
    return buffer
  }

  public func makeWAVData() throws -> Data {
    let buffer = try makePCMBuffer()
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
    try file.write(from: buffer)
    // AVAudioFile finalizes the WAV header when closed, before it is read back.
    file.close()
    return try Data(contentsOf: url)
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPAudioResponse: Hashable, Sendable {
  public let text: String
  public let audio: AppleLocalAILEAPAudioSamples?

  fileprivate init(text: String, samples: [Float], sampleRate: Int?) throws {
    if let sampleRate, !samples.isEmpty {
      audio = try AppleLocalAILEAPAudioSamples(samples: samples, sampleRate: sampleRate)
    } else {
      audio = nil
    }
    self.text = text
  }

  public func makePCMBuffer() throws -> AVAudioPCMBuffer {
    guard let audio else {
      throw AppleLocalAILEAPError.invalidAudioOutput("The response contains no audio.")
    }
    return try audio.makePCMBuffer()
  }

  public func makeWAVData() throws -> Data {
    guard let audio else {
      throw AppleLocalAILEAPError.invalidAudioOutput("The response contains no audio.")
    }
    return try audio.makeWAVData()
  }
}

@available(iOS 27.0, macOS 27.0, *)
public enum AppleLocalAILEAPAudioEvent: Sendable {
  case textDelta(String)
  case audio(AppleLocalAILEAPAudioSamples)
  case completed(AppleLocalAILEAPAudioResponse)
}

enum LEAPAudioStreamDelivery {
  static func yield(
    _ event: AppleLocalAILEAPAudioEvent,
    to continuation: AsyncThrowingStream<AppleLocalAILEAPAudioEvent, any Error>.Continuation
  ) {
    guard !Task.isCancelled else { return }
    continuation.yield(event)
  }
}

/// A loaded, actor-backed audio model. The native runner remains private to the
/// actor while AVFAudio-compatible values cross the public boundary.
@available(iOS 27.0, macOS 27.0, *)
public struct AppleLocalAILEAPAudioModel: Sendable {
  public let model: AppleLocalAILEAPAudioModelID
  private let runtime: AppleLocalAILEAPAudioRuntime

  fileprivate init(model: AppleLocalAILEAPAudioModelID, runtime: AppleLocalAILEAPAudioRuntime) {
    self.model = model
    self.runtime = runtime
  }

  public func generate(
    _ request: AppleLocalAILEAPAudioRequest
  ) async throws -> AppleLocalAILEAPAudioResponse {
    try await runtime.generate(request, model: model)
  }

  public func stream(
    _ request: AppleLocalAILEAPAudioRequest
  ) -> AsyncThrowingStream<AppleLocalAILEAPAudioEvent, any Error> {
    runtime.stream(request, model: model)
  }
}

@available(iOS 27.0, macOS 27.0, *)
public actor AppleLocalAILEAPAudioRuntime {
  private static let maximumOutputSeconds = 120
  private static let maximumTextBytes = 16 * 1_024
  private static let maximumGenerationTokens: Int32 = 512

  private let rootURL: URL
  private let minimumFreeBytes: UInt64
  private var residentModel: AppleLocalAILEAPAudioModelID?
  private var runner: (any ModelRunner)?
  private var nativeOperationActive = false

  public init(
    rootURL: URL,
    minimumFreeBytes: UInt64 = 128 * 1024 * 1024
  ) throws {
    let normalizedRoot = rootURL.standardizedFileURL
    try LEAPArtifactStore.validateArtifactRootBeforeCreation(at: normalizedRoot)
    self.rootURL = normalizedRoot
    self.minimumFreeBytes = minimumFreeBytes
    try FileManager.default.createDirectory(
      at: self.rootURL,
      withIntermediateDirectories: true)
  }

  @discardableResult
  public func prepareAudioModel(
    _ model: AppleLocalAILEAPAudioModelID = .recommended,
    progress: (@Sendable (AppleLocalAILEAPDownloadProgress) -> Void)? = nil
  ) async throws -> AppleLocalAILEAPPreparedAudioModel {
    _ = try await LEAPArtifactStore.prepare(
      files: model.artifactFiles,
      rootURL: rootURL,
      minimumFreeBytes: minimumFreeBytes,
      progress: progress)
    return AppleLocalAILEAPPreparedAudioModel(model: model, directoryURL: rootURL)
  }

  public func makeAudioModel(
    from prepared: AppleLocalAILEAPPreparedAudioModel
  ) async throws -> AppleLocalAILEAPAudioModel {
    try Task.checkCancellation()
    guard !nativeOperationActive else { throw AppleLocalAILEAPError.modelBusy }
    nativeOperationActive = true
    defer { nativeOperationActive = false }
    // Use canonical paths for the application-support directory. URL value
    // equality is stricter than path identity on a device.
    guard LEAPPathIdentity.canonical(prepared.directoryURL) == LEAPPathIdentity.canonical(rootURL)
    else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    for artifact in prepared.model.artifactFiles {
      try LEAPArtifactStore.validate(
        file: rootURL.appending(path: artifact.fileName, directoryHint: .notDirectory),
        against: artifact)
    }

    var loadedForThisCall = false
    if residentModel != prepared.model || runner == nil {
      guard runner == nil else { throw AppleLocalAILEAPError.modelBusy }
      let files = prepared.model.artifactFiles
      do {
        runner = try await LeapInferenceEngine.shared.loadModel(
          modelPath: rootURL.appending(path: files[0].fileName).path,
          mmprojPath: rootURL.appending(path: files[1].fileName).path,
          audioDecoderPath: rootURL.appending(path: files[2].fileName).path,
          audioTokenizerPath: nil,
          options: nil,
          generationTimeParameters: nil)
        residentModel = prepared.model
        loadedForThisCall = true
      } catch is CancellationError {
        runner = nil
        residentModel = nil
        throw CancellationError()
      } catch {
        runner = nil
        residentModel = nil
        throw AppleLocalAILEAPError.nativeFailure(String(describing: error))
      }
    }
    do {
      try Task.checkCancellation()
    } catch {
      if loadedForThisCall, let loadedRunner = runner {
        do {
          try await loadedRunner.unload()
          runner = nil
          residentModel = nil
        } catch {
          // Preserve the loaded runner for a later explicit unload. The
          // original cancellation remains the result of this operation.
        }
      }
      throw error
    }
    return AppleLocalAILEAPAudioModel(model: prepared.model, runtime: self)
  }

  public func unload() async throws {
    try Task.checkCancellation()
    guard !nativeOperationActive else { throw AppleLocalAILEAPError.modelBusy }
    nativeOperationActive = true
    defer { nativeOperationActive = false }
    guard let runner else {
      residentModel = nil
      return
    }
    do {
      try await runner.unload()
      self.runner = nil
      residentModel = nil
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AppleLocalAILEAPError.nativeFailure(String(describing: error))
    }
  }

  fileprivate func generate(
    _ request: AppleLocalAILEAPAudioRequest,
    model: AppleLocalAILEAPAudioModelID
  ) async throws -> AppleLocalAILEAPAudioResponse {
    try await run(request, model: model) { _ in }
  }

  fileprivate nonisolated func stream(
    _ request: AppleLocalAILEAPAudioRequest,
    model: AppleLocalAILEAPAudioModelID
  ) -> AsyncThrowingStream<AppleLocalAILEAPAudioEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let response = try await self.run(request, model: model) { event in
            switch event {
            case .textDelta(let text):
              LEAPAudioStreamDelivery.yield(.textDelta(text), to: continuation)
            case .audio(let samples):
              LEAPAudioStreamDelivery.yield(.audio(samples), to: continuation)
            }
          }
          try Task.checkCancellation()
          LEAPAudioStreamDelivery.yield(.completed(response), to: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(
    _ request: AppleLocalAILEAPAudioRequest,
    model: AppleLocalAILEAPAudioModelID,
    emit: @escaping @Sendable (LEAPAudioRuntimeEvent) async -> Void
  ) async throws -> AppleLocalAILEAPAudioResponse {
    try Task.checkCancellation()
    guard !nativeOperationActive else { throw AppleLocalAILEAPError.modelBusy }
    guard residentModel == model, let runner else {
      throw AppleLocalAILEAPError.modelNotPrepared
    }
    try validate(request)
    nativeOperationActive = true
    defer { nativeOperationActive = false }

    let systemPrompt: String
    let message: ChatMessage
    switch request {
    case .transcribe(let audio):
      systemPrompt = "Perform ASR."
      message = ChatMessage(
        role: .user,
        content: try ChatMessageContent.fromFloatSamples(
          audio.samples,
          sampleRate: audio.sampleRate))
    case .synthesize(let text, let voice):
      systemPrompt = voice.systemPrompt
      message = ChatMessage(role: .user, textContent: text)
    case .speechToSpeech(let audio):
      systemPrompt = "Respond with interleaved text and audio."
      message = ChatMessage(
        role: .user,
        content: try ChatMessageContent.fromFloatSamples(
          audio.samples,
          sampleRate: audio.sampleRate))
    }

    let conversation: any Conversation
    if case .speechToSpeech = request {
      conversation = Conversation(
        modelRunner: runner,
        history: [ChatMessage(role: .system, textContent: systemPrompt)])
    } else {
      conversation = runner.createConversation(systemPrompt: systemPrompt)
    }

    let options = GenerationOptions().with(maxTokens: Self.maximumGenerationTokens)
    var text = ""
    var audioSamples: [Float] = []
    var audioRate: Int?
    var textBytes = 0
    var terminalSeen = false

    try await withTaskCancellationHandler {
      for await response in conversation.generateResponse(
        message: message,
        generationOptions: options)
      {
        try Task.checkCancellation()
        if let chunk = response as? MessageResponseChunk {
          guard !terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
          let bytes = chunk.text.utf8.count
          let (newBytes, overflow) = textBytes.addingReportingOverflow(bytes)
          guard !overflow, newBytes <= Self.maximumTextBytes else {
            throw AppleLocalAILEAPError.outputLimitExceeded
          }
          textBytes = newBytes
          text.append(chunk.text)
          if !chunk.text.isEmpty { await emit(.textDelta(chunk.text)) }
        } else if let sample = response as? MessageResponseAudioSample {
          guard !terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
          let rate = Int(sample.sampleRate)
          let values = sample.samples.toFloatArray()
          guard rate == 24_000, !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw AppleLocalAILEAPError.invalidAudioOutput(
              "LEAP audio output must be finite mono PCM at 24 kHz.")
          }
          let limit = Self.maximumOutputSeconds * rate
          let (newCount, overflow) = audioSamples.count.addingReportingOverflow(values.count)
          guard !overflow, newCount <= limit else {
            throw AppleLocalAILEAPError.outputLimitExceeded
          }
          audioSamples.append(contentsOf: values)
          audioRate = rate
          await emit(
            .audio(
              try AppleLocalAILEAPAudioSamples(
                samples: values,
                sampleRate: rate)))
        } else if response is MessageResponseReasoningChunk {
          continue
        } else if response is MessageResponseFunctionCalls {
          throw AppleLocalAILEAPError.nativeFailure("The audio model emitted a function call.")
        } else if response is MessageResponseError {
          throw AppleLocalAILEAPError.nativeFailure("LEAP returned an audio generation error.")
        } else if let complete = response as? MessageResponseComplete {
          guard !terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
          switch complete.finishReason {
          case .stop:
            terminalSeen = true
          case .exceedContext, .constraint:
            throw AppleLocalAILEAPError.outputLimitExceeded
          case .interrupted:
            throw CancellationError()
          case .error:
            throw AppleLocalAILEAPError.nativeFailure("LEAP ended with an audio error.")
          }
        } else {
          throw AppleLocalAILEAPError.invalidRuntimeOutput
        }
      }
    } onCancel: {
      // Cancelling the async-flow collector invokes LEAP's native stop hook.
      // This is the SDK-supported cancellation boundary for a Conversation.
    }

    try Task.checkCancellation()
    guard terminalSeen else { throw AppleLocalAILEAPError.invalidRuntimeOutput }
    switch request {
    case .transcribe:
      guard !text.isEmpty, audioSamples.isEmpty else {
        throw AppleLocalAILEAPError.invalidRuntimeOutput
      }
    case .synthesize:
      guard !audioSamples.isEmpty else {
        throw AppleLocalAILEAPError.invalidRuntimeOutput
      }
    case .speechToSpeech:
      guard !text.isEmpty, !audioSamples.isEmpty else {
        throw AppleLocalAILEAPError.invalidRuntimeOutput
      }
    }
    return try AppleLocalAILEAPAudioResponse(
      text: text,
      samples: audioSamples,
      sampleRate: audioRate)
  }

  private func validate(_ request: AppleLocalAILEAPAudioRequest) throws {
    switch request {
    case .transcribe, .speechToSpeech:
      break
    case .synthesize(let text, _):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        text.utf8.count <= Self.maximumTextBytes,
        text.unicodeScalars.allSatisfy(\.isASCII)
      else {
        throw AppleLocalAILEAPError.invalidAudioInput(
          "LEAP English TTS requires non-empty ASCII text up to 16 KiB.")
      }
    }
  }
}

private enum LEAPAudioRuntimeEvent: Sendable {
  case textDelta(String)
  case audio(AppleLocalAILEAPAudioSamples)
}
