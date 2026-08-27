import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// Writes a 5K PNG, the size doc 03 §4's budget is written against.
private func writeCapture(width: Int = 5120, height: Int = 2880) throws -> URL {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a test bitmap context")
    }
    // Noise rather than flat colour, so PNG cannot compress the file to nothing and the
    // decode actually costs what a real screenshot costs.
    for row in stride(from: 0, to: height, by: 8) {
        context.setFillColor(CGColor(srgbRed: Double(row % 255) / 255, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: row, width: width, height: 8))
    }
    guard let image = context.makeImage() else {
        fatalError("Could not create a test image")
    }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kadr-pin-\(UUID().uuidString).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Could not create a test image destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write the test image")
    }
    return url
}

/// This process's physical footprint, which is what the PRD budgets are written in.
private func footprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

@MainActor
@Suite("Pinned screenshots", .serialized)
struct PinManagerTests {
    @Test("Pinning shows a window and closing all takes them away")
    func pinAndCloseAll() throws {
        let manager = PinManager()
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }))
        #expect(manager.count == 1)

        manager.closeAll()
        #expect(manager.isEmpty)
    }

    @Test("A file that is not an image cannot be pinned")
    func refusesNonImages() throws {
        let manager = PinManager()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-not-an-image-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }) == false)
        #expect(manager.isEmpty)
    }

    @Test("Pins cascade instead of landing exactly on top of each other")
    func pinsCascade() throws {
        let manager = PinManager()
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0 ..< 3 {
            manager.pin(url, copy: { _ in }, save: { _ in })
        }
        let origins = NSApp.windows
            .filter { $0 is PinPanel && $0.isVisible }
            .map(\.frame.origin)

        #expect(manager.count == 3)
        #expect(Set(origins.map(\.debugDescription)).count == origins.count, "pins landed on top of each other")
        manager.closeAll()
    }

    /// Doc 03 §4's acceptance criterion, measured rather than assumed.
    ///
    /// Twenty 5K screenshots are ~1.2 GB of pixels at full resolution. Pins show a
    /// texture sized to their window instead, and this is the harness that proves it.
    @Test("Twenty pinned 5K captures stay inside the 40 MB budget (docs/03 §4)")
    func twentyPinsFitTheBudget() throws {
        let url = try writeCapture()
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = PinManager()
        defer { manager.closeAll() }

        // Pin one first, so framework warm-up is not counted against the budget.
        manager.pin(url, copy: { _ in }, save: { _ in })
        let baseline = footprintBytes()

        for _ in 0 ..< 19 {
            manager.pin(url, copy: { _ in }, save: { _ in })
        }
        let added = footprintBytes() - baseline

        #expect(manager.count == 20)
        #expect(
            added < 40 * 1024 * 1024,
            "20 pins added \(added / 1024 / 1024) MB, over the 40 MB budget in doc 03 §4"
        )
    }
}
