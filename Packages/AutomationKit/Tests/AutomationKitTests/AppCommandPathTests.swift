import Foundation
import Testing
@testable import AutomationKit

/// docs/17 T-OUT-13: the CLI resolves paths in the user's directory, not the agent's `/`.
@Suite("Command paths")
struct AppCommandPathTests {
    private let cwd = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)

    @Test("File paths resolve against the shell's directory", arguments: [
        ("shot.png", "/Users/me/Desktop/shot.png"),
        ("../shot.png", "/Users/me/shot.png"),
        ("./a/../b.png", "/Users/me/Desktop/b.png"),
        ("/tmp/abs.png", "/tmp/abs.png")
    ])
    func resolves(input: String, expected: String) {
        let command = AppCommand.pin(FileTarget(path: input)).resolvingPaths(against: cwd)
        #expect(command == .pin(FileTarget(path: expected)))
    }

    @Test("A tilde path expands to the home folder, not the shell's directory")
    func tilde() {
        let command = AppCommand.annotate(FileTarget(path: "~/shot.png")).resolvingPaths(against: cwd)
        #expect(command == .annotate(FileTarget(path: NSHomeDirectory() + "/shot.png")))
    }

    @Test("capture-text's path is resolved too")
    func captureTextPath() {
        let command = AppCommand.captureText(CaptureOptions(path: "scan.png")).resolvingPaths(against: cwd)
        #expect(command == .captureText(CaptureOptions(path: "/Users/me/Desktop/scan.png")))
    }

    @Test("Commands with no file are unchanged")
    func unchanged() {
        #expect(AppCommand.openHistory.resolvingPaths(against: cwd) == .openHistory)
        #expect(AppCommand.pin(nil).resolvingPaths(against: cwd) == .pin(nil))
    }
}
