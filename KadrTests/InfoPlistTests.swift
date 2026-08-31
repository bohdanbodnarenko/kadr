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

    @Test("The agent declares camera, microphone, screen capture and speech usage")
    func agentUsageDescriptions() throws {
        let pbx = try String(
            contentsOf: repoRoot.appendingPathComponent("Kadr.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        for key in [
            "INFOPLIST_KEY_NSCameraUsageDescription",
            "INFOPLIST_KEY_NSMicrophoneUsageDescription",
            "INFOPLIST_KEY_NSScreenCaptureUsageDescription",
            "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription"
        ] {
            #expect(pbx.contains(key), "\(key) is missing from the agent target")
        }

        let info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleIdentifier"] as? String == "app.kadr.Kadr" {
            // Screen capture is not in this list, and cannot be. macOS has no
            // app-supplied usage string for Screen Recording — the system writes its own
            // prompt and sends the user to System Settings — so Xcode does not recognise
            // `INFOPLIST_KEY_NSScreenCaptureUsageDescription` and silently drops it rather
            // than synthesising a key. The build setting is still asserted above, because
            // its presence is what a reader checks for, but asserting a *runtime* value
            // macOS never populates failed every run for a permission that works fine.
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
