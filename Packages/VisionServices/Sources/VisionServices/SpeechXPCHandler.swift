import CryptoKit
import Foundation
import os
import Shared
import Speech

/// The helper's speech surface (docs/13 T1).
///
/// One place so HelperToolsMain stays a switchboard: extract, pick an engine, transcribe,
/// post-process nothing (that is a domain concern), and hand JSON back.
public enum SpeechXPCHandler {
    private static let logger = KadrLog.logger(.recording)
    private static let signposter = KadrLog.signposter(.recording)

    public static func transcribe(
        requestData: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let request = try JSONDecoder().decode(SpeechTranscriptionRequest.self, from: requestData)
        let media = URL(fileURLWithPath: request.mediaPath)
        let locale = Locale(identifier: request.localeIdentifier)
        let interval = signposter.beginInterval("speech.transcribe")
        defer { signposter.endInterval("speech.transcribe", interval) }

        progress(0.02)
        try Task.checkCancellation()

        let extracted = try await AudioExtractor().extract(from: media, selection: request.tracks)
        defer {
            for item in extracted {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        progress(0.12)

        guard let engine = await SpeechEngineRegistry().engine(for: locale) else {
            throw VisionServiceError.speechUnavailable
        }
        progress(0.18)

        var words: [SpeechWordDTO] = []
        for (index, item) in extracted.enumerated() {
            try Task.checkCancellation()
            let slice = try await engine.transcribe(audioAt: item.url, locale: locale)
            let labelled = slice.map { word in
                SpeechWordDTO(text: word.text, start: word.start, end: word.end, track: item.track)
            }
            words.append(contentsOf: labelled)
            let fraction = 0.18 + 0.75 * Double(index + 1) / Double(max(extracted.count, 1))
            progress(min(fraction, 0.93))
        }

        let hash = try hashFile(at: media)
        let dto = SpeechTranscriptDTO(
            words: words.sorted { $0.start < $1.start },
            audioContentHash: hash,
            localeIdentifier: locale.identifier,
            engine: engine.kind.rawValue
        )
        progress(1)
        return try JSONEncoder().encode(dto)
    }

    public static func status(requestData: Data) async throws -> Data {
        let request = try JSONDecoder().decode(SpeechStatusRequest.self, from: requestData)
        let locale = Locale(identifier: request.localeIdentifier)
        let installer = SpeechModelInstaller()
        let status = await installer.status(locale: locale)
        let supported = await installer.supportedLocales()
        let resolved = await installer.resolvedLocale(for: locale)
        let response = SpeechStatusResponse(
            status: status,
            supportedLocales: supported,
            resolvedLocale: resolved.identifier,
            dictationSettingsNeeded: installer.dictationSettingsNeeded(locale: locale)
        )
        return try JSONEncoder().encode(response)
    }

    public static func install(
        requestData: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let request = try JSONDecoder().decode(SpeechInstallRequest.self, from: requestData)
        let locale = Locale(identifier: request.localeIdentifier)
        do {
            try await SpeechModelInstaller().install(locale: locale) { systemProgress in
                progress(systemProgress.fractionCompleted)
            }
        } catch SpeechModelInstaller.InstallError.insufficientDiskSpace {
            throw VisionServiceError.insufficientDiskSpace
        } catch SpeechModelInstaller.InstallError.unsupportedLanguage {
            throw VisionServiceError.speechUnavailable
        } catch SpeechModelInstaller.InstallError.unavailable {
            throw VisionServiceError.speechUnavailable
        }
        return try await JSONEncoder().encode(SpeechStatusResponse(
            status: SpeechModelInstaller().status(locale: locale),
            resolvedLocale: locale.identifier
        ))
    }

    public static func warmUp(requestData: Data) async throws -> Data {
        let request = try JSONDecoder().decode(SpeechStatusRequest.self, from: requestData)
        let locale = Locale(identifier: request.localeIdentifier)
        _ = await SpeechEngineRegistry().engine(for: locale)
        return try JSONEncoder().encode(true)
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Refcount + memory-pressure unload (docs/13 T1.5).
///
/// The helper is the garbage collector — process exit gives the model back. This exists
/// so a long-lived helper that transcribed once does not keep the model resident while
/// it sits idle waiting for the 30 s terminator.
public final class SpeechModelLifecycle: @unchecked Sendable {
    public static let shared = SpeechModelLifecycle()

    private let lock = NSLock()
    private var active = 0
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(label: "app.kadr.helper.speech-pressure")
        )
        source.setEventHandler { [weak self] in
            self?.unloadIfIdle()
        }
        source.resume()
        pressureSource = source
    }

    public func begin() {
        lock.lock()
        active += 1
        lock.unlock()
    }

    public func end() {
        lock.lock()
        active = max(0, active - 1)
        let idle = active == 0
        lock.unlock()
        if idle {
            unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        lock.lock()
        let idle = active == 0
        lock.unlock()
        guard idle else { return }
        // Nothing to unload explicitly on Apple's engines — reservations are released
        // per-transcription. The pressure source exists so a future engine (whisper)
        // has a place to drop its weights.
    }
}
