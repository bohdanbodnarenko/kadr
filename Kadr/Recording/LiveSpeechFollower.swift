import AVFoundation
import Foundation
import os
import RecordingCore
import Shared
import StudioSession

/// Listens while somebody reads, and says where in the script they are (docs/13 T2.1).
///
/// Audio is captured here with `AVAudioEngine` — AVFoundation, not Speech. The buffers
/// cross XPC into the helper, which is the only process that loads Speech.framework.
/// Hypotheses come back as words; `SpeechFollower` decides where in the script that is.
/// Agreement across two consecutive hypotheses is required before the position moves,
/// and a retraction never scrolls backwards.
@MainActor
final class LiveSpeechFollower {
    private let logger = KadrLog.logger(.recording)
    private let script: TeleprompterScript
    private let follower = SpeechFollower()
    private var agreement = HypothesisAgreement()
    private let client = VisionClient()
    private var engine: AVAudioEngine?
    private var isPaused = false

    private(set) var position: Int?

    init(script: TeleprompterScript) {
        self.script = script
    }

    func start(microphone: AsyncStream<SampleBufferBox>? = nil) async -> Bool {
        guard !script.isEmpty else { return false }
        isPaused = false
        do {
            try await client.startLiveSpeech(SpeechLiveStartRequest(
                localeIdentifier: Locale.current.identifier,
                sampleRate: 16000
            )) { [weak self] hypothesis in
                Task { @MainActor in
                    self?.ingest(hypothesis.words)
                }
            }
            if let microphone {
                listen(to: microphone)
            } else {
                try startTap()
            }
            logger.info("Speech following started")
            return true
        } catch {
            logger.error("Speech following unavailable: \(error.localizedDescription, privacy: .public)")
            client.stopLiveSpeech()
            return false
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        client.stopLiveSpeech()
        position = nil
    }

    func pause() {
        isPaused = true
        engine?.pause()
    }

    func resume() {
        isPaused = false
        try? engine?.start()
    }

    func advanceForTesting(heard: [String]) {
        ingest(heard)
    }

    private func ingest(_ heard: [String]) {
        let confirmed = agreement.confirmed(from: heard)
        guard !confirmed.isEmpty else { return }
        let next = follower.position(heard: confirmed, in: script, from: position ?? 0)
        if let current = position, next < current {
            return
        }
        position = next
    }

    private func listen(to microphone: AsyncStream<SampleBufferBox>) {
        Task { [weak self] in
            for await box in microphone {
                guard let pcm = MicrophonePCM.int16kHzMono(from: box.buffer) else { continue }
                await MainActor.run {
                    guard let self, !self.isPaused else { return }
                    self.client.feedLiveSpeechAudio(pcm)
                }
            }
        }
    }

    private func startTap() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw CancellationError()
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CancellationError()
        }
        let state = TapConversion(converter: converter, outputFormat: outputFormat, inputRate: inputFormat.sampleRate)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let pcm = state.convert(buffer) else { return }
            Task { @MainActor in
                self?.client.feedLiveSpeechAudio(pcm)
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }
}

/// Converts one tap buffer to 16 kHz Int16 PCM. A class so the audio-thread callback
/// can hold it without crossing Sendable checks on AVAudioConverter.
private final nonisolated class TapConversion: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputRate: Double

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat, inputRate: Double) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.inputRate = inputRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = outputFormat.sampleRate / inputRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let source = PCMOnce(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if source.consumed {
                status.pointee = .noDataNow
                return nil
            }
            source.consumed = true
            status.pointee = .haveData
            return source.buffer
        }
        guard error == nil, converted.frameLength > 0, let channel = converted.int16ChannelData?[0] else {
            return nil
        }
        return Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
    }
}

private final nonisolated class PCMOnce: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
