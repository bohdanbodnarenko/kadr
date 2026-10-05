import Foundation
import Testing
@testable import Kadr

/// Build identity, the diagnostics zip's contents and the problem-report URL
/// (docs/17 T-REL-5, T-DIAG-1, T-DIAG-2, T-SH-3).
@Suite("Build identity")
struct BuildIdentityTests {
    @Test("Info dictionaries read as testers will see them", arguments: [
        (
            ["CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "512", "KadrGitCommit": "abc1234"],
            "0.9.0 (512 · abc1234)"
        ),
        (
            ["CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "512", "KadrGitCommit": "unknown"],
            "0.9.0 (512)"
        ),
        (
            ["CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "512", "KadrGitCommit": "$(KADR_GIT_COMMIT)"],
            "0.9.0 (512)"
        ),
        (["CFBundleShortVersionString": "1.2", "CFBundleVersion": "7"], "1.2 (7)"),
        ([:], "— (—)")
    ])
    func displayString(info: [String: String], expected: String) {
        #expect(BuildIdentity(infoDictionary: info).displayString == expected)
    }

    @Test("Only a pre-1.0 build is a prerelease", arguments: [
        ("0.9.0", true), ("0.1", true), ("1.0", false), ("2.3.1", false), ("—", false)
    ])
    func prerelease(version: String, expected: Bool) {
        #expect(BuildIdentity(version: version, build: "1", commit: nil).isPrerelease == expected)
    }
}

@Suite("Update channel")
struct UpdateChannelPreferenceTests {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "kadr.tests.channel.\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("A dogfood build follows beta until the user says otherwise")
    func dogfoodDefaultsToBeta() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = UpdateChannelPreference(
            defaults: defaults,
            build: BuildIdentity(version: "0.9.0", build: "1", commit: nil)
        )
        #expect(preference.allowedChannels == ["beta"])
        preference.receivesBetaBuilds = false
        #expect(preference.allowedChannels.isEmpty)
        #expect(defaults.object(forKey: UpdateChannelPreference.key) as? Bool == false)
    }

    @Test("A release build stays on releases by default")
    func releaseDefaultsToStable() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = UpdateChannelPreference(
            defaults: defaults,
            build: BuildIdentity(version: "1.0", build: "1", commit: nil)
        )
        #expect(preference.allowedChannels.isEmpty)
        preference.receivesBetaBuilds = true
        #expect(preference.allowedChannels == [UpdateChannelPreference.betaChannel])
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("Where the app runs from", arguments: [
        ("/Applications/Kadr.app", RunLocation.applications),
        ("/Users/tester/Applications/Kadr.app", .userApplications),
        ("/Volumes/Kadr 0.9.0/Kadr.app", .diskImage),
        ("/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/Kadr.app", .translocated),
        ("/Users/tester/Library/Developer/Xcode/DerivedData/Kadr-abc/Build/Products/Debug/Kadr.app", .buildProducts),
        ("/Users/tester/Downloads/Kadr.app", .other)
    ])
    func runLocation(path: String, expected: RunLocation) {
        #expect(RunLocation.classify(bundlePath: path, home: "/Users/tester") == expected)
    }

    @Test("Only the disk image and translocation ask to move")
    func moveOffer() {
        #expect(RunLocation.diskImage.shouldOfferMove)
        #expect(RunLocation.translocated.shouldOfferMove)
        #expect(!RunLocation.applications.shouldOfferMove)
        #expect(!RunLocation.other.shouldOfferMove)
    }

    @Test("Paths lose the account name", arguments: [
        ("/Users/tester/Pictures/Kadr", "~/Pictures/Kadr"),
        ("/Users/tester", "~"),
        ("/Applications/Kadr.app", "/Applications/Kadr.app"),
        ("file:///Users/tester/Desktop", "file://~/Desktop")
    ])
    func redaction(input: String, expected: String) {
        #expect(DiagnosticsRedaction.redactingHome(input, home: "/Users/tester") == expected)
    }

    @Test("Settings show switches, numbers and enum values, and only that the rest is set")
    func settingsDescription() {
        let domain: [String: Any] = [
            "saveFolder": "/Users/tester/Desktop",
            "bookmark": Data(repeating: 1, count: 48),
            "showsMenuBarIcon": true,
            "overlayDuration": 6,
            "scrollAxis": "vertical",
            "NSWindow Frame Settings": "1 2 3 4",
            "recentFolders": ["/Users/tester/A", "/tmp/B"]
        ]
        let settings = DiagnosticsRedaction.settings(from: domain)
        #expect(settings["saveFolder"] == "<set>")
        #expect(settings["bookmark"] == "<48 bytes>")
        #expect(settings["showsMenuBarIcon"] == "true")
        #expect(settings["overlayDuration"] == "6")
        #expect(settings["scrollAxis"] == "vertical")
        #expect(settings["recentFolders"] == "<2 items>")
        #expect(settings["NSWindow Frame Settings"] == nil, "AppKit's bookkeeping is noise in a report")
    }

    /// docs/18 SH-1: what the user wrote or named never reaches a diagnostics summary.
    @Test("Personal strings never appear in the summary", arguments: [
        "Hi, I'm Sam and today we'll look at the new dashboard.",
        "/Users/tester/Pictures/backdrop.heic",
        "backdrop.png",
        "com.tinyspeck.slackmacgap",
        "file:///Users/tester/Desktop/",
        "Kadr {date} at {time}"
    ])
    func personalStringsRedacted(value: String) {
        let settings = DiagnosticsRedaction.settings(from: [
            "teleprompterScript": value,
            "nested": ["consented": [value]]
        ])
        for description in settings.values {
            #expect(!description.contains(value))
        }
        #expect(settings["teleprompterScript"] == "<set>")
    }

    @Test("Crash reports are Kadr's own and nobody else's", arguments: [
        ("Kadr-2026-09-24-101010.ips", true),
        ("KadrEditor-2026-09-24-101010.ips", true),
        ("HelperTools_2026-09-24-101010_Mac.hang", true),
        ("kadr-2026-09-24.crash", true),
        ("KadrlessApp-2026-09-24.ips", false),
        ("Safari-2026-09-24.ips", false),
        ("Kadr-2026-09-24.txt", false)
    ])
    func crashReportFilter(name: String, expected: Bool) {
        #expect(DiagnosticsExporter.isKadrReport(named: name) == expected)
    }

    @Test("File stamps sort in time order")
    func fileStamps() {
        let early = DiagnosticsExporter.fileStamp(Date(timeIntervalSince1970: 1_000_000), timeZone: .gmt)
        let late = DiagnosticsExporter.fileStamp(Date(timeIntervalSince1970: 2_000_000), timeZone: .gmt)
        #expect(early == "1970-01-12-134640")
        #expect(early < late)
    }

    @Test("MetricKit keeps the newest thirty, across both kinds")
    func metricKitPruning() {
        let names = (1 ... 35).map { index in
            let kind = index.isMultiple(of: 2) ? "metrics" : "diagnostics"
            return String(format: "\(kind)-2026-09-24-%06d.json", index)
        } + ["notes.txt"]
        let pruned = MetricKitCollector.filesToPrune(names, keeping: 30)
        #expect(pruned.count == 5)
        #expect(Set(pruned) == Set(names.prefix(5)), "the oldest go first, whatever their kind")
        #expect(!pruned.contains("notes.txt"))
        let kept = Set(names).subtracting(pruned).filter { $0.hasSuffix(".json") }
        #expect(kept.count == 30)
    }

    @Test("The summary is JSON a person can diff")
    func snapshotEncodes() throws {
        let snapshot = DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            app: .init(version: "0.9.0", build: "5", commit: "abc", bundlePath: "~/x", runLocation: .other),
            system: .init(
                macOS: "15.0",
                osBuild: "24A",
                hardwareModel: "Mac",
                architecture: "arm64",
                isTranslated: false,
                freeDiskBytes: 1
            ),
            displays: [],
            permissions: ["screen": "Allowed"],
            hotkeyConflicts: [:],
            loginItem: "enabled",
            settings: [:],
            storage: .init(studioSessionCount: 0, studioSessionBytes: 0, historyItemCount: 3)
        )
        let decoded = try JSONDecoder.iso8601.decode(DiagnosticsSnapshot.self, from: snapshot.encoded())
        #expect(decoded == snapshot)
        #expect(snapshot.summaryText.contains("\"runLocation\" : \"other\""))
    }
}

@Suite("Problem report")
struct ProblemReportTests {
    private let identity = BuildIdentity(version: "0.9.0", build: "512", commit: "abc1234")

    @Test("The issue form is prefilled with the build and nothing that identifies anyone")
    func issueForm() throws {
        let url = try #require(ProblemReport.url(
            for: identity,
            macOS: "15.1.0",
            destination: .issueForm("https://example.com/o/r/issues/new")
        ))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "template": "bug.yml",
            "labels": "dogfood",
            "version": "0.9.0",
            "build": "512 (abc1234)",
            "os": "15.1.0"
        ])
        #expect(url.host == "example.com")
        #expect(!url.absoluteString.contains(NSUserName()))
    }

    @Test("The mail fallback carries the same facts")
    func mail() throws {
        let url = try #require(ProblemReport.url(for: identity, macOS: "15.1.0", destination: .mail("t@example.com")))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.contains("t@example.com"))
        #expect(url.absoluteString.contains("512"))
    }
}

@Suite("Single instance")
struct SingleInstanceTests {
    @Test("A second copy yields, except to a relaunch or a test host", arguments: [
        (0, [String](), [String: String](), false),
        (1, [], [:], true),
        (1, ["-KadrRelaunched"], [:], false),
        (1, [], ["XCTestConfigurationFilePath": "/x"], false),
        (2, [], [:], true)
    ])
    func yielding(others: Int, arguments: [String], environment: [String: String], expected: Bool) {
        #expect(SingleInstance.shouldYield(
            otherInstanceCount: others,
            arguments: arguments,
            environment: environment
        ) == expected)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
