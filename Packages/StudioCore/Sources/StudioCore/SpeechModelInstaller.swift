import Foundation
import os
import Shared
import Speech

/// Fetching the on-device speech model, when the user asks for it (docs/09 U3.6).
///
/// The one place in Kadr besides the Sparkle updater where something leaves the machine,
/// and the terms are narrow enough to state completely:
///
/// * It happens only when a person presses a button that says so. Nothing on the
///   transcription path calls this, and nothing calls it at launch.
/// * Nothing waits for it. Transcription works with whatever is already installed and
///   fails cleanly when nothing is; a machine that is offline, or whose user never presses
///   the button, behaves exactly as it did before this existed.
/// * It is the system's own model catalogue, downloaded by the system. Kadr opens no
///   socket, and the recording never leaves the machine either way — the point of the whole
///   arrangement is that the model comes *to* the audio.
///
/// The alternative was refusing to fetch at all, which spared nobody anything: it left a
/// user whose language happened not to be preinstalled with a feature that could never work
/// and no way to say what was missing.
public struct SpeechModelInstaller: Sendable {
    private let logger = KadrLog.logger(.recording)

    public init() {}

    /// Whether a language can be transcribed, and whether it can be yet.
    public enum Status: Sendable, Hashable {
        /// The system has no model for this language and never will.
        case unsupported
        /// A model exists and could be downloaded.
        case available
        /// A download is already running, started here or in System Settings.
        case downloading
        /// Ready to use, offline.
        case installed
        /// This system is too old for `SpeechAnalyzer`, so there is nothing to install —
        /// `SFSpeechRecognizer` uses whatever the system already has.
        case notApplicable

        /// Whether transcription can run right now without fetching anything.
        public var isReady: Bool {
            self == .installed
        }

        /// Whether offering a download would do anything.
        public var canInstall: Bool {
            self == .available
        }
    }

    public enum InstallError: Error, Equatable, Sendable {
        case unsupportedLanguage
        case unavailable
        case failed(String)
    }

    // MARK: - Asking

    /// What state this language's model is in.
    public func status(locale: Locale = .current) async -> Status {
        guard #available(macOS 26, *) else { return .notApplicable }
        guard Speech.SpeechTranscriber.isAvailable else { return .notApplicable }
        guard let module = await Self.module(for: locale) else { return .unsupported }

        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .available
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    // MARK: - Fetching

    /// Downloads and installs the model for a language.
    ///
    /// Only ever called from a control the user pressed. Cancellable, because a download
    /// nobody can stop is a download that owns the machine — `Task.cancel()` on the
    /// enclosing task stops it.
    ///
    /// - Parameter progress: handed the system's `Progress` once the download starts, so a
    ///   caller can show a bar and cancel it. Called at most once.
    public func install(
        locale: Locale = .current,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        guard #available(macOS 26, *), Speech.SpeechTranscriber.isAvailable else {
            throw InstallError.unavailable
        }
        guard let module = await Self.module(for: locale) else {
            throw InstallError.unsupportedLanguage
        }
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            // No request means nothing to fetch. That is the already-installed case as
            // often as it is the unsupported one, so it is not an error.
            logger.info("The speech model needs no download")
            return
        }

        progress?(request.progress)
        do {
            try await request.downloadAndInstall()
            logger.info("Installed the on-device speech model")
        } catch {
            logger.error("The speech model download failed: \(error.localizedDescription, privacy: .public)")
            throw InstallError.failed(error.localizedDescription)
        }
    }

    /// The transcription module for the nearest language the system supports.
    ///
    /// `en_GB` and `en_US` are separate models, so asking for the user's exact locale and
    /// giving up would refuse a download to somebody whose language exists under a
    /// neighbouring identifier.
    @available(macOS 26, *)
    private static func module(for locale: Locale) async -> Speech.SpeechTranscriber? {
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
}
