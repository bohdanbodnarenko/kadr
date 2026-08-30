import AVFoundation
import Foundation
import os
import Shared
import Speech

/// Turning a recording's audio into words with times on them (docs/09 U3.6).
///
/// Separate from the planner because this is the part that changes with the operating
/// system, and the planner is the part worth keeping. A planner tied to a speech API would
/// have to be written once per API and tested through a microphone.
///
/// There are two of these behind the protocol. `SpeechAnalyzer` on macOS 26 and later is
/// the one Apple is developing; `SFSpeechRecognizer` is what macOS 14 and 15 have. The
/// newer one is preferred when it can actually run, not merely when the system is new
/// enough, because "new enough" and "has the model installed" are different questions.
public protocol Transcribing: Sendable {
    func transcribe(audioAt url: URL) async throws -> Transcript
}

public enum TranscriptionError: Error, Equatable, Sendable {
    /// Speech recognition is not permitted, or was declined.
    case notAuthorized
    /// No on-device model for this language — or none installed yet.
    case unavailableOnDevice
    case noAudioTrack
    case failed(String)
}

// MARK: - The one to use

/// Transcribes with the newest speech API this machine can actually run.
///
/// On device, always. Neither backend may fall back to Apple's servers: rule 1 is about
/// network calls Kadr makes, and a speech API that uploads the user's recording is a
/// network call Kadr made. That one is absolute — the audio never leaves the machine.
///
/// Fetching the *model* is a separate question with a separate answer, and it lives in
/// `SpeechModelInstaller` rather than here on purpose. Nothing on this path downloads
/// anything and nothing on this path waits for a download: transcription uses whatever is
/// already installed and fails cleanly when nothing is. A machine that is offline behaves
/// exactly as it would have if the installer did not exist.
public struct AudioTranscriber: Transcribing {
    private let logger = KadrLog.logger(.recording)
    private let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Whether a transcript can be produced at all, without asking for permission.
    public static func isAvailable(locale: Locale = .current) async -> Bool {
        if #available(macOS 26, *), await AnalyzerTranscriber(locale: locale).isReady() {
            return true
        }
        return LegacyTranscriber.isAvailable(locale: locale)
    }

    /// Asks for permission, once. Both backends are gated by the same authorisation.
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
        guard try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first != nil else {
            throw TranscriptionError.noAudioTrack
        }
        if #available(macOS 26, *) {
            let analyzer = AnalyzerTranscriber(locale: locale)
            if await analyzer.isReady() {
                logger.info("Transcribing with SpeechAnalyzer")
                return try await analyzer.transcribe(audioAt: url)
            }
        }
        logger.info("Transcribing with SFSpeechRecognizer")
        return try await LegacyTranscriber(locale: locale).transcribe(audioAt: url)
    }
}

// MARK: - macOS 26 and later

/// The `SpeechAnalyzer` backend.
@available(macOS 26, *)
struct AnalyzerTranscriber: Transcribing {
    let locale: Locale

    /// Whether the model for this language is already on the machine.
    ///
    /// Asked before every transcription rather than once at launch, because a model can be
    /// installed — or removed — from System Settings while Kadr is running.
    func isReady() async -> Bool {
        guard Speech.SpeechTranscriber.isAvailable else { return false }
        guard let module = await module() else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    func transcribe(audioAt url: URL) async throws -> Transcript {
        // `.installed` and nothing else. A model that is merely *supported* would be
        // downloaded by `SpeechAnalyzer` on demand, which would turn a transcription into a
        // silent multi-hundred-megabyte fetch and block until it finished. Downloading is
        // the installer's job, and only when somebody asked for it.
        guard let module = await module(),
              await AssetInventory.status(forModules: [module]) == .installed
        else {
            throw TranscriptionError.unavailableOnDevice
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        // The results sequence has to be drained while the audio is being fed in: it does
        // not finish until the analyzer does, so collecting afterwards would deadlock.
        async let collected = words(from: module)
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            _ = try? await collected
            throw TranscriptionError.failed(error.localizedDescription)
        }
        return try await Transcript(words: collected)
    }

    /// The transcription module, asked for the closest language the system supports.
    ///
    /// `en_GB` and `en_US` are different models; asking for the user's exact locale and
    /// giving up when it is missing would deny a transcript to somebody whose language is
    /// installed under a neighbouring identifier.
    private func module() async -> Speech.SpeechTranscriber? {
        guard let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        return Speech.SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            // No volatile results: the planner wants the final wording, and a partial
            // result would put a word in the transcript that the next one takes away.
            reportingOptions: [],
            // The whole point — a transcript without times says "um" was in there
            // somewhere and nothing more.
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Drains the module's results into words.
    private func words(from module: Speech.SpeechTranscriber) async throws -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for try await result in module.results {
            let text = result.text
            for run in text.runs {
                let span = run.audioTimeRange ?? result.range
                words += TranscriptAssembly.words(
                    in: String(text[run.range].characters),
                    start: span.start.seconds,
                    end: span.end.seconds
                )
            }
        }
        return words
    }
}

// MARK: - macOS 14 and 15

/// The `SFSpeechRecognizer` backend.
struct LegacyTranscriber: Transcribing {
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    static func isAvailable(locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func transcribe(audioAt url: URL) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.unavailableOnDevice
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Rather than fall back to the network.
            throw TranscriptionError.unavailableOnDevice
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
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
