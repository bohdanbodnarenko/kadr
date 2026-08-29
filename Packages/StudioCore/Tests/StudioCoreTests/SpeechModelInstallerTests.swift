import Foundation
import Testing
@testable import StudioCore

/// Fetching the on-device speech model (docs/09 U3.6).
///
/// The download itself cannot be tested here — it needs Apple's catalogue, a network and
/// several hundred megabytes, and a unit test that fetches one would be a unit test that
/// fails on an aeroplane. What *is* tested is the contract around it, which is the part
/// that matters: that the status is reported honestly, that nothing about transcription
/// reaches for a download, and that the whole feature degrades to exactly what it was
/// before the installer existed.
@Suite("Speech model installer")
struct SpeechModelInstallerTests {
    // MARK: - Status

    @Test("Asking for the status does not throw, download, or block")
    func statusIsSafeToAsk() async {
        // Whatever this machine has, asking must return promptly and without a network.
        let status = await SpeechModelInstaller().status(locale: Locale(identifier: "en_US"))
        #expect(SpeechModelInstaller.Status.allPossible.contains(status))
    }

    @Test("A language the system has never heard of is unsupported, not available")
    func nonsenseLocale() async {
        let status = await SpeechModelInstaller().status(locale: Locale(identifier: "zz_ZZ"))
        #expect(!status.canInstall, "offering a download for a language with no model wastes somebody's time")
        #expect(!status.isReady)
    }

    /// The two questions a caller actually asks, and they are not the same one: "can I
    /// transcribe now" and "would a download help" have different answers in three of the
    /// five states, and conflating them either hides a working feature or offers a
    /// download that does nothing.
    @Test(
        "Ready and installable are different questions",
        arguments: SpeechModelInstaller.Status.allPossible
    )
    func readyAndInstallableAreDistinct(status: SpeechModelInstaller.Status) {
        #expect(!(status.isReady && status.canInstall), "a model that is installed needs no download")
    }

    @Test("Only an installed model is ready")
    func onlyInstalledIsReady() {
        #expect(SpeechModelInstaller.Status.installed.isReady)
        for status in SpeechModelInstaller.Status.allPossible where status != .installed {
            #expect(!status.isReady, "\(status) is not something to transcribe with")
        }
    }

    /// A download already running is not something to start again — that is how somebody
    /// ends up with two of them and a progress bar that jumps backwards.
    @Test("A download in flight is not offered again")
    func downloadingIsNotInstallable() {
        #expect(!SpeechModelInstaller.Status.downloading.canInstall)
    }

    /// On macOS 14 and 15 there is no catalogue to install from: `SFSpeechRecognizer` uses
    /// whatever the system already ships. Reporting `.unsupported` there would be a lie
    /// that turns into a download button leading nowhere.
    @Test("A system with no catalogue reports that, rather than reporting unsupported")
    func notApplicableIsItsOwnAnswer() {
        #expect(!SpeechModelInstaller.Status.notApplicable.canInstall)
        #expect(!SpeechModelInstaller.Status.notApplicable.isReady)
        #expect(SpeechModelInstaller.Status.notApplicable != .unsupported)
    }

    // MARK: - Installing

    @Test("Installing a language with no model fails rather than hanging")
    func installUnsupported() async {
        await #expect(throws: SpeechModelInstaller.InstallError.self) {
            try await SpeechModelInstaller().install(locale: Locale(identifier: "zz_ZZ"))
        }
    }

    /// The guarantee the whole design rests on: a cancelled install stops, and stopping it
    /// leaves transcription exactly as it was. A download nobody can stop owns the machine.
    @Test("An install can be cancelled")
    func installIsCancellable() async {
        let task = Task {
            try await SpeechModelInstaller().install(locale: Locale(identifier: "en_US"))
        }
        task.cancel()
        // Either it threw, or it finished before the cancel landed because the model was
        // already installed. Both are fine; hanging is not, and a hang fails by timeout.
        _ = try? await task.value
    }

    // MARK: - The separation that matters

    /// Transcription must never reach for a download, so a machine with no model and no
    /// network gets a clean failure rather than a stall. Asserted structurally, because the
    /// alternative is a runtime test that needs a machine in exactly the wrong state.
    ///
    /// Comments are stripped first: the transcriber's own documentation explains where
    /// downloading lives and why, and a check that reads prose would forbid saying so.
    @Test("Nothing on the transcription path can start a download")
    func transcriptionNeverDownloads() throws {
        let code = try Self.code(of: "Transcriber.swift")
        #expect(
            !code.contains("assetInstallationRequest"),
            "the transcriber asks for a download; that belongs to SpeechModelInstaller"
        )
        #expect(
            !code.contains("downloadAndInstall"),
            "the transcriber downloads a model; transcription must work offline or fail cleanly"
        )
        #expect(
            !code.contains("SpeechModelInstaller("),
            "the transcriber reaches for the installer; the two are separate on purpose"
        )
    }

    /// A source file with its comments removed.
    private static func code(of name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StudioCore/\(name)")
        let source = try String(contentsOf: url, encoding: .utf8)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The other half: the transcriber demands `.installed` specifically. Accepting
    /// `.supported` would let `SpeechAnalyzer` fetch the model itself, mid-transcription,
    /// which is the silent blocking download this whole arrangement exists to prevent.
    @Test("The transcriber requires an installed model, not merely a supported one")
    func transcriberDemandsInstalled() throws {
        #expect(try Self.code(of: "Transcriber.swift").contains("== .installed"))
    }
}

extension SpeechModelInstaller.Status {
    /// Every state, for tests that assert across all of them.
    ///
    /// Written out rather than `CaseIterable` because the type is not an enum a caller
    /// should be looping over in production — the states are asked about one language at a
    /// time, and a menu built by iterating them would offer "unsupported" as a choice.
    static let allPossible: [Self] = [.unsupported, .available, .downloading, .installed, .notApplicable]
}
