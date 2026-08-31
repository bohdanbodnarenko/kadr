import AVFoundation
import Foundation
import os
import Shared
import Speech

/// Live recognition for the teleprompter, in the helper (docs/13 T2.1).
///
/// The agent sends 16 kHz mono Int16 PCM; this appends it to an on-device
/// `SFSpeechAudioBufferRecognitionRequest` and pushes hypotheses back. Nothing here
/// lives in the agent — that is why `LiveSpeechFollower.start()` used to return false.
public final class LiveSpeechEngine: @unchecked Sendable {
    private let logger = KadrLog.logger(.recording)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var onHypothesis: (@Sendable (SpeechHypothesisDTO) -> Void)?

    public init() {}

    public func start(
        locale: Locale,
        sampleRate: Double,
        onHypothesis: @escaping @Sendable (SpeechHypothesisDTO) -> Void
    ) throws {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw VisionServiceError.speechUnavailable
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            throw VisionServiceError.speechUnavailable
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw VisionServiceError.transcriptionFailed
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        self.recognizer = recognizer
        self.request = request
        self.format = format
        self.onHypothesis = onHypothesis

        let callback = onHypothesis
        task = recognizer.recognitionTask(with: request) { result, error in
            if error != nil {
                return
            }
            guard let result else { return }
            let words = result.bestTranscription.segments.map(\.substring)
            callback(SpeechHypothesisDTO(words: words, isFinal: result.isFinal))
        }
        logger.info("Live speech started")
    }

    public func append(pcm: Data) {
        lock.lock()
        let request = request
        let format = format
        lock.unlock()
        guard let request, let format, !pcm.isEmpty else { return }
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let dest = buffer.int16ChannelData?[0], let src = raw.bindMemory(to: Int16.self).baseAddress {
                dest.update(from: src, count: frames)
            }
        }
        request.append(buffer)
    }

    public func stop() {
        lock.lock()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        format = nil
        onHypothesis = nil
        lock.unlock()
    }
}
