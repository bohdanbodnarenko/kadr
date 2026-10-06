import AVFoundation
import Foundation
import os
import Shared
import Speech

/// One `transcribe` method, several engines (docs/13 T1.2).
///
/// The registry picks by availability. `RequestContext` is the choke point: options an
/// engine does not have are stripped before they reach it, so adding a field cannot
/// silently change Apple's on-device path.
protocol SpeechEngine: Sendable {
    var kind: SpeechEngineKind { get }
    func isReady(locale: Locale) async -> Bool
    /// - Parameter progress: how many seconds of the audio are done, when the engine can
    ///   tell. An engine that cannot report nothing, and the caller shows elapsed time.
    func transcribe(
        audioAt url: URL,
        locale: Locale,
        progress: (@Sendable (TimeInterval) -> Void)?
    ) async throws -> [SpeechWordDTO]
}

enum SpeechEngineKind: String, Sendable {
    case appleAnalyzer
    case appleLegacy
}

struct SpeechRequestContext: Sendable {
    var locale: Locale
    var tracks: SpeechTrackSelection

    func scoped(to engine: SpeechEngineKind) -> SpeechRequestContext {
        // Both shipping engines honour locale and ignore the rest. The method exists so
        // a third engine (whisper, later) has somewhere to drop prompt / temperature.
        switch engine {
        case .appleAnalyzer, .appleLegacy:
            SpeechRequestContext(locale: locale, tracks: tracks)
        }
    }
}

/// Picks the newest engine this machine can actually run.
struct SpeechEngineRegistry: Sendable {
    func engine(for locale: Locale) async -> (any SpeechEngine)? {
        if #available(macOS 26, *) {
            let analyzer = AnalyzerEngine()
            if await analyzer.isReady(locale: locale) {
                return analyzer
            }
        }
        let legacy = LegacyEngine()
        if await legacy.isReady(locale: locale) {
            return legacy
        }
        return nil
    }

    func supportedLocales() async -> [String] {
        if #available(macOS 26, *), Speech.SpeechTranscriber.isAvailable {
            return await Speech.SpeechTranscriber.supportedLocales.map(\.identifier)
        }
        return [Locale.current.identifier]
    }
}

// MARK: - Word splitting

/// The same character-count split `TranscriptAssembly` uses, so timings degrade the same
/// way when a run covers a phrase rather than a word. Lives here because VisionServices
/// cannot import StudioRender.
enum SpeechWordSplitter {
    static func words(
        in text: String,
        start: TimeInterval,
        end: TimeInterval,
        track: SpeechTrackKind
    ) -> [SpeechWordDTO] {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else { return [] }
        let total = text.count
        let duration = max(0, end - start)
        guard total > 0, duration > 0 else {
            return tokens.map { SpeechWordDTO(text: $0.text, start: start, end: start, track: track) }
        }
        return tokens.map { token in
            SpeechWordDTO(
                text: token.text,
                start: start + duration * Double(token.offset) / Double(total),
                end: start + duration * Double(token.offset + token.text.count) / Double(total),
                track: track
            )
        }
    }

    private struct Token {
        let text: String
        let offset: Int
    }

    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0
        for (offset, character) in text.enumerated() {
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(Token(text: current, offset: start))
                    current = ""
                }
                start = offset + 1
            } else {
                if current.isEmpty {
                    start = offset
                }
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(Token(text: current, offset: start))
        }
        return tokens
    }
}

// MARK: - macOS 26

@available(macOS 26, *)
struct AnalyzerEngine: SpeechEngine {
    let kind = SpeechEngineKind.appleAnalyzer

    func isReady(locale: Locale) async -> Bool {
        guard Speech.SpeechTranscriber.isAvailable else { return false }
        guard let module = await module(for: locale) else { return false }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    func transcribe(
        audioAt url: URL,
        locale: Locale,
        progress: (@Sendable (TimeInterval) -> Void)?
    ) async throws -> [SpeechWordDTO] {
        guard let module = await module(for: locale),
              await AssetInventory.status(forModules: [module]) == .installed
        else {
            throw VisionServiceError.speechUnavailable
        }

        let reserved = try await AssetInventory.reserve(locale: locale)
        defer {
            if reserved {
                Task { _ = await AssetInventory.release(reservedLocale: locale) }
            }
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VisionServiceError.transcriptionFailed
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        // Drain while feeding: the sequence does not finish until the analyzer does, so
        // collecting afterwards deadlocks. Start the consumer *after* the analyzer exists
        // and *before* `analyzeSequence` — the drain race called out in docs/13 T-M5.
        let collected = Task { try await words(from: module, progress: progress) }
        // A cancelled tidy stops the analyzer too, rather than letting it read the rest of
        // the file in the helper (docs/17 T-STU-5).
        let boxed = AnalyzerBox(analyzer)
        do {
            try await withTaskCancellationHandler {
                _ = try await boxed.analyzer.analyzeSequence(from: file)
                try await boxed.analyzer.finalizeAndFinishThroughEndOfInput()
            } onCancel: {
                collected.cancel()
                Task { await boxed.analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collected.cancel()
            _ = try? await collected.value
            if Task.isCancelled {
                throw CancellationError()
            }
            throw VisionServiceError.transcriptionFailed
        }
        return try await collected.value
    }

    private func module(for locale: Locale) async -> Speech.SpeechTranscriber? {
        guard let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        return Speech.SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    private func words(
        from module: Speech.SpeechTranscriber,
        progress: (@Sendable (TimeInterval) -> Void)?
    ) async throws -> [SpeechWordDTO] {
        var words: [SpeechWordDTO] = []
        for try await result in module.results {
            try Task.checkCancellation()
            // Results arrive in audio order, so the end of each is how far the analyzer
            // has read (docs/18 STU-9).
            progress?(result.range.end.seconds)
            let text = result.text
            for run in text.runs {
                let span = run.audioTimeRange ?? result.range
                words += SpeechWordSplitter.words(
                    in: String(text[run.range].characters),
                    start: span.start.seconds,
                    end: span.end.seconds,
                    track: .mixed
                )
            }
        }
        return words
    }
}

/// Hands the analyzer to the cancellation handler, which runs on another thread.
@available(macOS 26, *)
private struct AnalyzerBox: @unchecked Sendable {
    let analyzer: SpeechAnalyzer

    init(_ analyzer: SpeechAnalyzer) {
        self.analyzer = analyzer
    }
}

// MARK: - macOS 14 / 15

struct LegacyEngine: SpeechEngine {
    let kind = SpeechEngineKind.appleLegacy

    func isReady(locale: Locale) async -> Bool {
        Self.isAvailable(locale: locale)
    }

    static func isAvailable(locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func transcribe(
        audioAt url: URL,
        locale: Locale,
        progress _: (@Sendable (TimeInterval) -> Void)?
    ) async throws -> [SpeechWordDTO] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VisionServiceError.speechUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VisionServiceError.speechUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return try await recognize(request, with: recognizer)
    }

    private func recognize(
        _ request: SFSpeechURLRecognitionRequest,
        with recognizer: SFSpeechRecognizer
    ) async throws -> [SpeechWordDTO] {
        let box = ResumeBox()
        // The recognition task is kept and cancelled with the Swift task (docs/17 T-STU-5).
        // Dropping it meant a cancelled Tidy kept recognising the whole file in the helper,
        // and pressing Tidy again ran two at once.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if error != nil {
                        let failure: any Error = box.wasCancelled
                            ? CancellationError()
                            : VisionServiceError.transcriptionFailed
                        box.resume(continuation, with: .failure(failure))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let words = result.bestTranscription.segments.map { segment in
                        SpeechWordDTO(
                            text: segment.substring,
                            start: segment.timestamp,
                            end: segment.timestamp + segment.duration,
                            track: .mixed
                        )
                    }
                    box.resume(continuation, with: .success(words))
                }
                box.hold(task, continuation: continuation)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Resumes the continuation once, and owns the recognition task so a cancel can reach it.
    ///
    /// `@unchecked Sendable` under the lock: every field is read and written holding it.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false
        private var task: SFSpeechRecognitionTask?
        private var isCancelled = false

        /// Keeps `task`, or cancels it at once if the Swift task was cancelled first.
        func hold(
            _ task: SFSpeechRecognitionTask,
            continuation: CheckedContinuation<[SpeechWordDTO], any Error>
        ) {
            lock.lock()
            let cancelledAlready = isCancelled
            if !cancelledAlready {
                self.task = task
            }
            lock.unlock()
            if cancelledAlready {
                task.cancel()
                resume(continuation, with: .failure(CancellationError()))
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            self.task = nil
            lock.unlock()
            // Cancelling makes the recognizer call back with an error, which resumes the
            // continuation; the caller sees the cancellation, not a failure.
            task?.cancel()
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }

        func resume(
            _ continuation: CheckedContinuation<[SpeechWordDTO], any Error>,
            with result: Result<[SpeechWordDTO], any Error>
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(with: result)
        }
    }
}
