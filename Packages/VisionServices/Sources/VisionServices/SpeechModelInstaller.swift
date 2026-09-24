import Foundation
import os
import Shared
import Speech

/// Fetching the on-device speech model, when the user asks for it (docs/09 U3.6, docs/13).
///
/// The one place in Kadr besides the Sparkle updater where something leaves the machine.
/// Lives in VisionServices so the download, the reservation and the model itself all die
/// with the helper process (docs/13 T1.1, CLAUDE.md rule 1).
public struct SpeechModelInstaller: Sendable {
    private let logger = KadrLog.logger(.recording)

    /// Rough size of Apple's on-device model, used for the disk-space precheck. The
    /// catalogue does not publish a byte count before the download starts; two gigabytes
    /// is a ceiling, not a measurement.
    public static let estimatedByteCount: Int64 = 2_000_000_000

    public init() {}

    public enum InstallError: Error, Equatable, Sendable {
        case unsupportedLanguage
        case unavailable
        case insufficientDiskSpace
        case failed(String)
    }

    public func status(locale: Locale = .current) async -> SpeechModelStatus {
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

    public func supportedLocales() async -> [String] {
        guard #available(macOS 26, *), Speech.SpeechTranscriber.isAvailable else {
            return [Locale.current.identifier]
        }
        return await Speech.SpeechTranscriber.supportedLocales.map(\.identifier)
    }

    public func resolvedLocale(for locale: Locale) async -> Locale {
        guard #available(macOS 26, *) else { return locale }
        if let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return supported
        }
        return locale
    }

    /// Whether Dictation has to be turned on in System Settings before the legacy
    /// recogniser will work (docs/13 T-H5).
    public func dictationSettingsNeeded(locale: Locale) -> Bool {
        if #available(macOS 26, *), Speech.SpeechTranscriber.isAvailable {
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return true }
        return !recognizer.supportsOnDeviceRecognition
    }

    public func install(
        locale: Locale = .current,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        guard #available(macOS 26, *), Speech.SpeechTranscriber.isAvailable else {
            throw InstallError.unavailable
        }
        guard Self.hasRoom(for: Self.estimatedByteCount) else {
            throw InstallError.insufficientDiskSpace
        }
        guard let module = await Self.module(for: locale) else {
            throw InstallError.unsupportedLanguage
        }
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            logger.info("The speech model needs no download")
            return
        }

        // Checked at every step (docs/17 T-STU-5). The user was told the download stopped
        // when they pressed Cancel, and a fetch that carried on anyway would make that a
        // lie about the one thing here that uses the network (CLAUDE.md rule 1).
        try Task.checkCancellation()
        let requestProgress = request.progress
        progress?(requestProgress)
        do {
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                // The request's progress is its cancel handle.
                requestProgress.cancel()
            }
            try Task.checkCancellation()
            logger.info("Installed the on-device speech model")
        } catch is CancellationError {
            throw CancellationError()
        } catch where Task.isCancelled {
            // A cancelled progress fails the request with its own error; it is still a cancel.
            throw CancellationError()
        } catch {
            logger.error("The speech model download failed: \(error.localizedDescription, privacy: .public)")
            throw InstallError.failed(error.localizedDescription)
        }
    }

    public static func hasRoom(for bytes: Int64, at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        // Half a gigabyte of slack: a download that fills the disk is worse than one that
        // refuses up front.
        return available > bytes + 500_000_000
    }

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
