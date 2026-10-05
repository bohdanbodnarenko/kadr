import Foundation
import Testing
@testable import Shared

/// The agent's in-place hand-off to the editor (docs/18 ED-1).
@Suite("Editor hand-off")
struct EditorHandoffTests {
    private func makeHandoff(lifetime: TimeInterval = 120) -> EditorHandoff {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorHandoffTests-\(UUID().uuidString)", isDirectory: true)
        return EditorHandoff(directory: directory, lifetime: lifetime)
    }

    @Test("A marked file is consumed once")
    func consumedOnce() throws {
        let handoff = makeHandoff()
        let file = URL(fileURLWithPath: "/Users/me/Desktop/Shot.png")
        try handoff.mark(file)
        #expect(handoff.consume(file))
        #expect(!handoff.consume(file))
    }

    @Test("An unmarked file is not a hand-off")
    func unmarked() {
        #expect(!makeHandoff().consume(URL(fileURLWithPath: "/Users/me/Desktop/Other.png")))
    }

    @Test("Equivalent spellings of one path match", arguments: [
        ("/Users/me/Desktop/Shot.png", "/Users/me/Desktop/./Shot.png"),
        ("/Users/me/Desktop/Shot.png", "/Users/me/Pictures/../Desktop/Shot.png")
    ])
    func standardised(marked: String, opened: String) throws {
        let handoff = makeHandoff()
        try handoff.mark(URL(fileURLWithPath: marked))
        #expect(handoff.consume(URL(fileURLWithPath: opened)))
    }

    @Test("A marker past its lifetime is ignored", arguments: [
        (10.0, true),
        (119.0, true),
        (121.0, false),
        (3600.0, false)
    ])
    func expiry(age: TimeInterval, accepted: Bool) throws {
        let handoff = makeHandoff()
        let file = URL(fileURLWithPath: "/Users/me/Desktop/Shot.png")
        try handoff.mark(file)
        #expect(handoff.consume(file, now: Date().addingTimeInterval(age)) == accepted)
    }

    @Test("The sweep removes only expired markers")
    func sweep() throws {
        let handoff = makeHandoff()
        let file = URL(fileURLWithPath: "/Users/me/Desktop/Shot.png")
        try handoff.mark(file)
        #expect(handoff.sweepExpired() == 0)
        #expect(handoff.sweepExpired(now: Date().addingTimeInterval(500)) == 1)
        #expect(!handoff.consume(file))
    }
}
