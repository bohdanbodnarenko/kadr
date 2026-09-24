import Foundation
import Testing

/// TCC usage strings and document types must exist before first use (docs/10 R3.5).
///
/// A missing `NSCameraUsageDescription` is a hard crash on `AVCaptureDevice.requestAccess`.
/// The same for speech and microphone. Finder import also needs `CFBundleDocumentTypes`.
@Suite("Info.plist")
struct InfoPlistTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("The agent declares camera, microphone and speech usage")
    func agentUsageDescriptions() throws {
        let pbx = try String(
            contentsOf: repoRoot.appendingPathComponent("Kadr.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        for key in [
            "INFOPLIST_KEY_NSCameraUsageDescription",
            "INFOPLIST_KEY_NSMicrophoneUsageDescription",
            "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription"
        ] {
            #expect(pbx.contains(key), "\(key) is missing from the agent target")
        }

        let info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleIdentifier"] as? String == "app.kadr.Kadr" {
            // Screen capture is not in this list, and cannot be: macOS has no app-supplied
            // usage string for Screen Recording. The system writes its own prompt, and
            // Xcode silently dropped the build setting that pretended otherwise, so it
            // is gone (docs/17 T-REL-8).
            for key in [
                "NSCameraUsageDescription",
                "NSMicrophoneUsageDescription",
                "NSSpeechRecognitionUsageDescription"
            ] {
                let value = info[key] as? String ?? ""
                #expect(!value.isEmpty, "\(key) is empty in the running agent")
            }
        }
    }

    /// Sparkle's keys were once `INFOPLIST_KEY_` build settings, which the generator
    /// dropped without a word: no build ever had a feed URL (docs/17 T-REL-2). This reads
    /// the *built* bundle, which is the only place that failure was visible.
    @Test("The built agent carries Sparkle's feed and key, and its build identity")
    func agentUpdateKeys() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == "app.kadr.Kadr" else { return }

        let feed = try #require(info["SUFeedURL"] as? String)
        let url = try #require(URL(string: feed))
        #expect(url.scheme == "https", "Sparkle refuses a feed that is not https")
        #expect(!(url.host ?? "").isEmpty)

        // Present always; empty in development, because only the owner holds the key.
        // Scripts/release.sh refuses to ship a build where it is still empty, and here
        // a non-empty value must at least be a 32-byte Ed25519 key in base64.
        let key = try #require(info["SUPublicEDKey"] as? String)
        if !key.isEmpty {
            #expect(Data(base64Encoded: key)?.count == 32, "SUPublicEDKey is not an Ed25519 public key")
        }

        let commit = try #require(info["KadrGitCommit"] as? String)
        #expect(!commit.isEmpty && !commit.contains("$("), "the build setting was not expanded")
        #expect(info["LSApplicationCategoryType"] as? String == "public.app-category.productivity")
        #expect(info["SUEnableInstallerLauncherService"] == nil, "only a sandboxed app needs it")
    }

    @Test("The editor declares speech, document types and the portable-preset UTI")
    func editorPlist() throws {
        let url = repoRoot.appendingPathComponent("Resources/KadrEditor-Info.plist")
        let dict = try #require(NSDictionary(contentsOf: url) as? [String: Any])

        let speech = dict["NSSpeechRecognitionUsageDescription"] as? String ?? ""
        #expect(!speech.isEmpty)

        let types = try #require(dict["CFBundleDocumentTypes"] as? [[String: Any]])
        let identifiers = types.flatMap { type in
            (type["LSItemContentTypes"] as? [String]) ?? []
        }
        #expect(identifiers.contains("public.png"))
        #expect(identifiers.contains("app.kadr.project"))
        #expect(identifiers.contains("app.kadr.recording-session"))
        #expect(identifiers.contains("app.kadr.preset"))

        let exported = try #require(dict["UTExportedTypeDeclarations"] as? [[String: Any]])
        let exportedIDs = exported.compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(exportedIDs.contains("app.kadr.preset"))
        #expect(exportedIDs.contains("app.kadr.project"))
        #expect(exportedIDs.contains("app.kadr.recording-session"))
    }
}
