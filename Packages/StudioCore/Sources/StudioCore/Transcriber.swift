import AVFoundation
import Foundation
import os
import Shared
import Speech

/// Turning a recording's audio into words with times on them (docs/09 U3.6).
///
/// Separate from the planner because this is the part that changes with the operating
/// system, and the planner is the part worth keeping. `SFSpeechRecognizer` is what macOS 14
/// and 15 have; later systems have better APIs. A planner tied to either would have to be
/// written twice and tested through a microphone.
///
/// On device, always. `requiresOnDeviceRecognition` is set unconditionally rather than
/// falling back to Apple's servers — CLAUDE.md rule 1 is about network calls Kadr makes,
/// and a speech API that uploads the user's recording is a network call Kadr made. A
/// machine or a language without an on-device model gets no transcript, which is a smaller
/// failure than a silent upload.
public protocol Transcribing: Sendable {
    func transcribe(audioAt url: URL) async throws -> Transcript
}

public enum TranscriptionError: Error, Equatable, Sendable {
    /// Speech recognition is not permitted, or was declined.
    case notAuthorized
    /// No on-device model for this language.
    case unavailableOnDevice
    case noAudioTrack
    case failed(String)
}

/// The `SFSpeechRecognizer` implementation, for macOS 14 and later.
public struct SpeechTranscriber: Transcribing {
    private let logger = KadrLog.logger(.recording)
    private let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Whether a transcript can be produced at all, without asking for permission.
    ///
    /// Checked before offering the feature, so the button is absent rather than present
    /// and disappointing.
    public static func isAvailable(locale: Locale = .current) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Asks for permission, once.
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func transcribe(audioAt url: URL) async throws -> Transcript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.unavailableOnDevice
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Rather than fall back to the network. A speech API that uploads the user's
            // recording is a network call Kadr made.
            throw TranscriptionError.unavailableOnDevice
        }
        guard try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first != nil else {
            throw TranscriptionError.noAudioTrack
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        // Word timings are the whole point: a sentence-level transcript can say "um" was
        // in there somewhere and nothing more.
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        // The transcript is assembled inside the callback rather than sent out of it:
        // `SFSpeechRecognitionResult` is not `Sendable`, and the words are.
        return try await recognize(request, with: recognizer)
    }

    /// The callback API as an async call, resumed exactly once.
    private func recognize(
        _ request: SFSpeechURLRecognitionRequest,
        with recognizer: SFSpeechRecognizer
    ) async throws -> Transcript {
        let box = ResumeBox()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                // Every path — an error, a final result, a partial that never finalises —
                // has to resume this exactly once, and the callback fires more than once.
                if let error {
                    box.resume(continuation, with: .failure(TranscriptionError.failed(
                        error.localizedDescription
                    )))
                    return
                }
                guard let result, result.isFinal else { return }
                let words = result.bestTranscription.segments.map { segment in
                    TranscriptWord(
                        text: segment.substring,
                        start: segment.timestamp,
                        end: segment.timestamp + segment.duration
                    )
                }
                box.resume(continuation, with: .success(Transcript(words: words)))
            }
        }
    }

    /// Resumes a continuation once, whatever the callback does.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false

        func resume(
            _ continuation: CheckedContinuation<Transcript, any Error>,
            with result: Result<Transcript, any Error>
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(with: result)
        }
    }
}
