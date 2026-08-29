import AVFoundation
import Foundation
import os
import Shared
import Speech
import StudioCore

/// Listens while somebody reads, and says where in the script they are (docs/08).
///
/// On device, always. `requiresOnDeviceRecognition` is set unconditionally: this listens to
/// a microphone continuously for the length of a recording, and a version of that which
/// uploaded would be the single worst thing in the application.
///
/// Entirely optional, and it fails quietly. No permission, no model, no microphone, or a
/// language the machine cannot transcribe — every one of those leaves the prompter
/// scrolling at the rate the user set, which is what it would have been doing anyway.
/// Nothing here is ever waited on and nothing here can stop a recording.
@MainActor
final class LiveSpeechFollower {
    private let logger = KadrLog.logger(.recording)
    private let script: TeleprompterScript
    private let follower = SpeechFollower()

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Where the reader appears to be, or nil until something has been heard.
    private(set) var position: Int?

    init(script: TeleprompterScript) {
        self.script = script
    }

    /// Starts listening. Returns false when it cannot, which is not an error.
    func start() async -> Bool {
        guard !script.isEmpty else { return false }
        guard await Self.isPermitted() else {
            logger.info("Speech recognition is not permitted; the prompter will scroll at a steady rate")
            return false
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            logger.info("No on-device speech model for this language; the prompter will scroll at a steady rate")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        // Partial results are the whole point: a prompter that waits for a final
        // transcription follows the reader several sentences late.
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request

        guard startEngine(feeding: request) else {
            self.request = nil
            return false
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let result else {
                if error != nil {
                    Task { @MainActor in self?.stop() }
                }
                return
            }
            // The transcription is read here and only words leave the callback:
            // `SFSpeechRecognitionResult` is not `Sendable`, and an array of strings is.
            let heard = result.bestTranscription.segments.map(\.substring)
            Task { @MainActor in self?.advance(heard: heard) }
        }
        return true
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    // MARK: - Listening

    /// Taps the microphone and feeds the recogniser.
    ///
    /// A separate `AVAudioEngine` from anything the recording uses. The recording's
    /// microphone track, if the user asked for one, is ScreenCaptureKit's business — and
    /// two consumers of one tap is a way to make a recording depend on a prompter.
    private func startEngine(feeding request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            logger.info("No microphone input; the prompter will scroll at a steady rate")
            return false
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.info("Could not listen: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        return true
    }

    /// Moves the reported position, if what was heard justifies it.
    private func advance(heard: [String]) {
        position = follower.position(heard: heard, in: script, from: position ?? 0)
    }

    /// Whether speech recognition has already been granted.
    ///
    /// Requested rather than assumed, but only once and only when the user has turned
    /// following on — a permission dialog at the instant a recording starts is a dialog in
    /// the recording.
    private static func isPermitted() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            false
        }
    }
}
