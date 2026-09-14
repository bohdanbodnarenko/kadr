import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Kadr

@MainActor
@Suite("Clipboard media")
struct ClipboardMediaTests {
    @Test("A file URL on a pasteboard is returned as-is")
    func fileURL() throws {
        let pasteboard = namedPasteboard()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-clip-\(UUID().uuidString).mp4")
        try Data("not a real movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(pasteboard.writeObjects([url as NSURL]))
        let found = try #require(ClipboardMedia.fileURL(from: pasteboard))
        #expect(found.path == url.path)
    }

    @Test("MPEG-4 bytes on the pasteboard become a temp .mp4")
    func movieData() throws {
        let pasteboard = namedPasteboard()
        let payload = Data("ftypisom".utf8)
        pasteboard.setData(
            payload,
            forType: NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier)
        )
        let found = try #require(ClipboardMedia.fileURL(from: pasteboard))
        defer { try? FileManager.default.removeItem(at: found) }
        #expect(found.pathExtension == "mp4")
        #expect(try Data(contentsOf: found) == payload)
    }

    @Test("An empty pasteboard has nothing to import")
    func empty() {
        let pasteboard = namedPasteboard()
        #expect(ClipboardMedia.fileURL(from: pasteboard) == nil)
        #expect(ClipboardMedia.stillPNG(from: pasteboard) == nil)
    }

    @Test("Plain text becomes a PNG card")
    func textCard() throws {
        let pasteboard = namedPasteboard()
        pasteboard.setString("Pin this note", forType: .string)
        let png = try #require(ClipboardMedia.stillPNG(from: pasteboard))
        #expect(png.count > 32)
        #expect(NSImage(data: png) != nil)
    }

    private func namedPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kadr-clip-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}
