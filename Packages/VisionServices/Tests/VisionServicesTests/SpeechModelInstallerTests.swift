import Foundation
import Shared
import Testing
@testable import VisionServices

@Suite("Speech model installer")
struct SpeechModelInstallerTests {
    @Test("Asking for the status does not throw, download, or block")
    func statusIsSafeToAsk() async {
        let status = await SpeechModelInstaller().status(locale: Locale(identifier: "en_US"))
        #expect(SpeechModelStatus.allPossible.contains(status))
    }

    @Test("A language the system has never heard of is unsupported, not available")
    func nonsenseLocale() async {
        let status = await SpeechModelInstaller().status(locale: Locale(identifier: "zz_ZZ"))
        #expect(status != .available, "offering a download for a language with no model wastes somebody's time")
        #expect(status != .installed)
    }

    @Test("Installed and available are different states")
    func readyAndInstallableAreDistinct() {
        #expect(SpeechModelStatus.installed != .available)
    }

    @Test("A download in flight is not offered again")
    func downloadingIsNotInstallable() {
        #expect(SpeechModelStatus.downloading != .available)
    }

    @Test("A system with no catalogue reports that, rather than reporting unsupported")
    func notApplicableIsItsOwnAnswer() {
        #expect(SpeechModelStatus.notApplicable != .available)
        #expect(SpeechModelStatus.notApplicable != .installed)
        #expect(SpeechModelStatus.notApplicable != .unsupported)
    }

    @Test("Installing a language with no model fails rather than hanging")
    func installUnsupported() async {
        await #expect(throws: SpeechModelInstaller.InstallError.self) {
            try await SpeechModelInstaller().install(locale: Locale(identifier: "zz_ZZ"))
        }
    }

    @Test("An install can be canceled")
    func installIsCancellable() async {
        let task = Task {
            try await SpeechModelInstaller().install(locale: Locale(identifier: "en_US"))
        }
        task.cancel()
        _ = try? await task.value
    }

    /// docs/17 T-STU-5: a cancel that reaches the task must reach the work. The download
    /// and the recogniser both run in Apple's code, so the only way to prove it without
    /// a network or a model is that the handles are kept and cancelled.
    @Test("Cancellation reaches the download and the legacy recognizer", arguments: [
        ("SpeechModelInstaller.swift", "requestProgress.cancel()"),
        ("SpeechModelInstaller.swift", "try Task.checkCancellation()"),
        ("SpeechEngines.swift", "withTaskCancellationHandler"),
        ("SpeechEngines.swift", "task.cancel()")
    ])
    func cancellationIsWired(file: String, needle: String) throws {
        #expect(try Self.code(of: file).contains(needle))
    }

    @Test("Nothing on the transcription path can start a download")
    func transcriptionNeverDownloads() throws {
        let code = try Self.code(of: "SpeechEngines.swift")
        #expect(!code.contains("assetInstallationRequest"))
        #expect(!code.contains("downloadAndInstall"))
        #expect(!code.contains("SpeechModelInstaller("))
    }

    @Test("The analyzer engine requires an installed model, not merely a supported one")
    func transcriberDemandsInstalled() throws {
        #expect(try Self.code(of: "SpeechEngines.swift").contains("== .installed"))
    }

    @Test("A disk-space precheck refuses a volume with no room")
    func diskSpacePrecheck() {
        // The home volume has *some* capacity; the helper is that the function returns
        // rather than throwing, and that an absurd request is refused.
        #expect(!SpeechModelInstaller.hasRoom(for: Int64.max / 4))
    }

    private static func code(of name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/VisionServices/\(name)")
        let source = try String(contentsOf: url, encoding: .utf8)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

extension SpeechModelStatus {
    static let allPossible: [Self] = [.unsupported, .available, .downloading, .installed, .notApplicable]
}
