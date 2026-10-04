import AVFoundation
import Foundation
import FoundationModels
import Testing

@testable import AppleLocalAILEAP

@Test func cancelledAudioStreamDoesNotPublishLateEvents() async throws {
  let stream = AsyncThrowingStream<AppleLocalAILEAPAudioEvent, any Error> { continuation in
    let producer = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      LEAPAudioStreamDelivery.yield(.textDelta("late"), to: continuation)
      continuation.finish()
    }
    _ = producer
  }
  var iterator = stream.makeAsyncIterator()
  let next = try await iterator.next()
  #expect(next == nil)
}

@Test(arguments: [false, true])
func downmixesFloatPCMUsingItsActualChannelLayout(interleaved: Bool) throws {
  let format = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
      channels: 2, interleaved: interleaved))
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
  buffer.frameLength = 3
  let channels = try #require(buffer.floatChannelData)
  let left: [Float] = [0.2, 0.6, -0.8]
  let right: [Float] = [0.4, -0.2, 0.2]
  for frame in 0..<3 {
    if interleaved {
      channels[0][frame * 2] = left[frame]
      channels[0][frame * 2 + 1] = right[frame]
    } else {
      channels[0][frame] = left[frame]
      channels[1][frame] = right[frame]
    }
  }
  let input = try AppleLocalAILEAPAudioInput(pcmBuffer: buffer)
  #expect(input.sampleRate == 24_000)
  #expect(input.samples.count == 3)
  for (actual, expected) in zip(input.samples, [Float(0.3), 0.2, -0.3]) {
    #expect(abs(actual - expected) < 0.00001)
  }
}

@Test func rejectsInvalidChannelsBeforeTheyCanCancelOutInAMix() throws {
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
  buffer.frameLength = 1
  let channels = try #require(buffer.floatChannelData)
  channels[0][0] = 2
  channels[1][0] = -2
  #expect(throws: AppleLocalAILEAPError.self) {
    _ = try AppleLocalAILEAPAudioInput(pcmBuffer: buffer)
  }
}

@Test(arguments: [Float(-1), Float(1)])
func downmixesFullScaleMultichannelPCMWithoutRoundingOutsideRange(value: Float) throws {
  let layout = try #require(
    AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 10))
  let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channelLayout: layout)
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
  buffer.frameLength = 1
  let channels = try #require(buffer.floatChannelData)
  for channel in 0..<10 { channels[channel][0] = value }
  let input = try AppleLocalAILEAPAudioInput(pcmBuffer: buffer)
  #expect(input.samples == [value])
}

@Test func finalizesWAVHeaderBeforeReturningAudioData() throws {
  let samples = (0..<480).map { Float(sin(Double($0) * 0.1)) * 0.5 }
  let output = try AppleLocalAILEAPAudioSamples(samples: samples, sampleRate: 24_000)
  let data = try output.makeWAVData()
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleLocalAI-WAV-\(UUID()).wav")
  defer { try? FileManager.default.removeItem(at: url) }
  try data.write(to: url)
  let file = try AVAudioFile(forReading: url)
  #expect(file.length == AVAudioFramePosition(samples.count))
  #expect(file.processingFormat.sampleRate == 24_000)
  #expect(file.processingFormat.channelCount == 1)
  let buffer = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
  try file.read(into: buffer)
  let decoded = try AppleLocalAILEAPAudioInput(pcmBuffer: buffer)
  for (actual, expected) in zip(decoded.samples, samples) {
    #expect(abs(actual - expected) < 0.00001)
  }
}

@Test func keepsByteAndTokenOutputLimitsIndependent() throws {
  let transcript = Transcript(entries: [
    .prompt(.init(segments: [.text(.init(content: "Say hello."))]))
  ])
  let plan = try LEAPTranscriptPlan.make(
    from: .init(
      id: UUID(), transcript: transcript, enabledTools: [], schema: nil,
      generationOptions: .init(maximumResponseTokens: 1), contextOptions: .init(), metadata: [:]))
  #expect(plan.maximumTokens == 1)
  #expect(plan.maximumOutputBytes == LEAPTranscriptPlan.maximumOutputBytes)
}
