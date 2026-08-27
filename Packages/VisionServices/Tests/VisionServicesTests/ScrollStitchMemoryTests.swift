import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import VisionServices

/// The memory half of the docs/03 §1.6 accept list: "memory stays bounded (stitch tiles
/// stream to disk beyond ~16k px tall)".
///
/// A 30,000-pixel page at this width is a 73 MB bitmap. The point of the memory-mapped
/// canvas is that the process never has to own that, so the test measures the real
/// footprint rather than trusting the design.
@Suite("Stitching a very long page", .serialized)
struct ScrollStitchMemoryTests {
    /// The process's physical footprint — the number Activity Monitor shows and the one
    /// the PRD §8 budgets are written against.
    private func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// A tall page: 640 × 520 frames scrolled a little over 30,000 pixels.
    private var fixture: ScrollFixture {
        ScrollFixture(
            name: "30k page",
            width: 640,
            frameHeight: 520,
            header: 0,
            footer: 0,
            scrollSteps: Array(repeating: 260, count: 116),
            drawRow: { y, row, width in
                for x in 0 ..< width {
                    row[x * 4] = 250
                    row[x * 4 + 1] = 250
                    row[x * 4 + 2] = 250
                    row[x * 4 + 3] = 255
                }
                // One bar per text line, its length unique to that line, so no offset
                // other than the true one can match. A repeating pattern would let the
                // aligner find a shorter answer that is just as good, which says nothing
                // about memory.
                guard y % 13 < 7 else { return }
                var value = UInt64(bitPattern: Int64(y / 13)) &+ 0x9E37_79B9_7F4A_7C15
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
                let length = 60 + Int((value ^ (value >> 31)) % UInt64(width - 140))
                for x in 20 ..< min(20 + length, width) {
                    row[x * 4] = 30
                    row[x * 4 + 1] = 30
                    row[x * 4 + 2] = 30
                }
            }
        )
    }

    @Test("A 30,000-pixel page stitches without the bitmap landing on the heap")
    func longPageStaysBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-stitch-memory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = fixture
        let frames = try fixture.writeFrames(to: directory)
        let destination = directory.appendingPathComponent("stitched.png")

        let before = footprintBytes()
        let response = try ScrollStitcher().stitch(frames: frames, to: destination)
        let peak = footprintBytes() - before

        #expect(response.pixelSize.height > 30000)
        #expect(response.seams.count == fixture.scrollSteps.count)

        // The finished bitmap alone would be this much on the heap.
        let bitmapBytes = response.pixelSize.width * response.pixelSize.height * 4
        #expect(bitmapBytes > 70_000_000, "the fixture should be big enough to matter")
        #expect(
            peak < bitmapBytes / 2,
            "stitching grew the footprint by \(peak / 1_048_576) MB; the bitmap alone is \(bitmapBytes / 1_048_576) MB"
        )
    }
}
