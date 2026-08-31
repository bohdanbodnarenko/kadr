import Foundation
import Shared
import Speech
import StudioSession

/// Talks to the helper for transcription (docs/13 T1.1).
///
/// Permission is asked here, in the editor, so the TCC prompt names Kadr rather than
/// the helper. Recognition itself runs in the helper so the model dies with that process.
public struct HelperTranscriber: Transcribing {
    public init() {}

    public func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public func transcribe(
        audioAt url: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        try await Self.run(url: url, options: options, progress: progress)
    }

    @MainActor
    private static func run(
        url: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        let client = VisionClient()
        defer { client.disconnect() }
        let request = SpeechTranscriptionRequest(
            mediaPath: url.path,
            localeIdentifier: options.localeIdentifier,
            tracks: options.tracks,
            timeoutSeconds: options.timeout
        )
        do {
            let dto = try await client.transcribe(request, progress: progress)
            return TranscriptPostProcessor().processed(Transcript(dto))
        } catch VisionServiceError.speechUnavailable {
            throw TranscriptionError.unavailableOnDevice
        } catch VisionServiceError.transcriptionFailed {
            throw TranscriptionError.failed("The recording could not be transcribed.")
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }
}
