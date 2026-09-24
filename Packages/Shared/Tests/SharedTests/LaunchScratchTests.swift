import Foundation
import Shared
import Testing

@Suite("Launch scratch")
struct LaunchScratchTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-scratch-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A launch sweeps earlier launches' folders and keeps its own")
    func sweepsEarlierLaunches() throws {
        let root = root()
        let earlier = LaunchScratch(root: root, launchID: "earlier")
        let leftover = try earlier.url(named: "Kadr-clipboard.png")
        try Data([1]).write(to: leftover)

        let now = LaunchScratch(root: root, launchID: "now")
        let mine = try now.url(named: "poster.jpg")
        try Data([2]).write(to: mine)

        #expect(now.sweepPreviousLaunches() == 1)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    @Test("Sweeping a root that does not exist yet is a no-op")
    func sweepWithNoRoot() {
        #expect(LaunchScratch(root: root()).sweepPreviousLaunches() == 0)
    }

    @Test("Two files with the same name never collide")
    func sameNameTwice() throws {
        let scratch = LaunchScratch(root: root())
        let first = try scratch.url(named: "Screenshot.png")
        let second = try scratch.url(named: "Screenshot.png")
        #expect(first != second)
        #expect(first.lastPathComponent == "Screenshot.png")
        #expect(second.lastPathComponent == "Screenshot.png")
    }

    @Test("A link carries the source's bytes under the new name")
    func linkKeepsBytes() throws {
        let scratch = LaunchScratch(root: root())
        let source = try scratch.url(named: "3fa9c1.png")
        try Data([7, 8, 9]).write(to: source)

        let linked = try scratch.link(source, named: "Receipt.png")

        #expect(linked.lastPathComponent == "Receipt.png")
        #expect(try Data(contentsOf: linked) == Data([7, 8, 9]))
    }
}
