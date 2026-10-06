import Foundation
import Testing
@testable import KadrEditor

/// Windows back after a quit, and a list of recoverable edits (docs/18 T-ED-7).
@MainActor
@Suite("Editor restoration")
struct EditorRestorationTests {
    private func defaults(keepsWindows: Bool) -> UserDefaults {
        let suite = "kadr-restoration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.set(keepsWindows, forKey: EditorRestoration.keepsWindowsKey)
        return defaults
    }

    private let shot = URL(fileURLWithPath: "/Users/me/Desktop/Shot.png")
    private let other = URL(fileURLWithPath: "/Users/me/Desktop/Other.png")

    @Test("With keep-windows on, the open set comes back once")
    func restoresOnce() {
        let restoration = EditorRestoration(defaults: defaults(keepsWindows: true))
        restoration.remember([shot, other])
        #expect(restoration.takeRestorable() == [shot, other])
        #expect(restoration.takeRestorable().isEmpty, "read once, so a bad file cannot loop")
    }

    @Test("With the system's close-windows-on-quit setting, nothing is kept")
    func respectsSystemSetting() {
        let restoration = EditorRestoration(defaults: defaults(keepsWindows: false))
        restoration.remember([shot])
        #expect(restoration.takeRestorable().isEmpty)
    }

    @Test("Launch plan: open captures are skipped, missing files dropped, nothing offered twice")
    func plan() {
        let missing = URL(fileURLWithPath: "/Users/me/Desktop/Gone.png")
        let recovered = URL(fileURLWithPath: "/Users/me/Desktop/Recovered.png")
        let result = EditorRestoration.plan(
            restorable: [shot, other, missing],
            recoveries: [other, recovered, shot],
            open: [shot],
            exists: { $0 != missing }
        )
        #expect(result.reopen == [other])
        #expect(result.offer == [recovered])
    }

    @Test("A studio session comes back with the captures, and is not reopened while open")
    func studioSessions() {
        let session = URL(fileURLWithPath: "/Users/me/Movies/Demo.kadrrec", isDirectory: true)
        let restoration = EditorRestoration(defaults: defaults(keepsWindows: true))
        restoration.remember([shot, session])
        let restored = restoration.takeRestorable()
        #expect(restored.map(\.standardizedFileURL.path) == [shot.path, session.standardizedFileURL.path])

        let reopened = EditorRestoration.plan(
            restorable: restored,
            recoveries: [],
            open: [session],
            exists: { _ in true }
        )
        #expect(reopened.reopen == [shot])
    }
}
