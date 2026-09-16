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
    private func makeManager() -> (PinManager, URL) {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pins-\(UUID().uuidString).json")
        return (PinManager(store: PinStore(fileURL: storeURL)), storeURL)
    }

    @Test("Pinning shows a window and closing all takes them away")
    func pinAndCloseAll() throws {
        let (manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }))
        #expect(manager.count == 1)

        manager.closeAll()
        #expect(manager.isEmpty)
    }

    @Test("A file that is not an image cannot be pinned")
    func refusesNonImages() throws {
        let (manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-not-an-image-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }) == false)
        #expect(manager.isEmpty)
    }

    @Test("Pins cascade instead of landing exactly on top of each other")
    func pinsCascade() throws {
        let (manager, storeURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: storeURL) }
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

        let (manager, storeURL) = makeManager()
        defer {
            manager.closeAll()
            try? FileManager.default.removeItem(at: storeURL)
        }

        // Pin one first, so framework warm-up is not counted against the budget.
        // Pins decode off the main thread; inline here, so the textures are all in hand
        // when the footprint is read and nothing else runs in between.
        PinPanel.decodesInlineForTesting = true
        defer { PinPanel.decodesInlineForTesting = false }
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

    @Test("Closing a pin forgets it, so a relaunch does not bring it back")
    func persistAndRestore() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pins-\(UUID().uuidString).json")
        let store = PinStore(fileURL: storeURL)
        let url = try writeCapture(width: 400, height: 300)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: storeURL)
        }

        let writer = PinManager(store: store)
        #expect(writer.pin(url, copy: { _ in }, save: { _ in }))
        writer.flushPendingSave()
        let saved = store.load()
        #expect(saved.count == 1)
        writer.closeAll()
        writer.flushPendingSave()
        #expect(store.load().isEmpty)

        store.save(saved)
        let reader = PinManager(store: store)
        reader.restore(copy: { _ in }, save: { _ in }, annotate: { _ in }, copyText: { _ in })
        #expect(reader.count == 1)
        reader.closeAll()
        reader.flushPendingSave()
        #expect(store.load().isEmpty)
    }

    /// Opacity scrolls and nudges arrive at trackpad rate; each used to be a pretty-printed
    /// JSON encode and an atomic write on the main thread (PRD §8).
    @Test("A burst of pin changes is one save, after the pins sit still")
    func savesAreCoalesced() async throws {
        let (manager, storeURL) = makeManager()
        defer {
            manager.closeAll()
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: storeURL)
        }
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }))
        let panel = try #require(pinPanels(showing: url).first)
        for step in 0 ..< 30 {
            panel.nudge(dx: 1, dy: CGFloat(step % 2))
        }
        #expect(manager.hasPendingSave)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path), "nothing is written mid-gesture")

        try await Task.sleep(for: PinManager.saveDebounce + .milliseconds(400))
        #expect(!manager.hasPendingSave)
        let deadline = ContinuousClock.now + .seconds(2)
        while PinStore(fileURL: storeURL).load().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = PinStore(fileURL: storeURL).load()
        #expect(saved.count == 1)
        #expect(saved.first?.x == Double(panel.frame.origin.x), "the save holds the last position")
    }

    @Test("Quitting writes a pending change at once")
    func flushWritesImmediately() throws {
        let (manager, storeURL) = makeManager()
        defer {
            manager.closeAll()
            manager.flushPendingSave()
            try? FileManager.default.removeItem(at: storeURL)
        }
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }))
        #expect(manager.hasPendingSave)
        manager.flushPendingSave()
        #expect(!manager.hasPendingSave)
        #expect(PinStore(fileURL: storeURL).load().count == 1)
    }

    /// Background writes may land in any order; an older snapshot must never overwrite a
    /// newer one — least of all the one flushed at quit.
    @Test("An older snapshot never overwrites a newer one", arguments: [
        ([1, 2, 3], [true, true, true], 3),
        ([2, 1], [true, false], 2),
        ([3, 1, 2], [true, false, false], 3),
        ([1, 1], [true, false], 1)
    ])
    func writerKeepsTheNewest(generations: [Int], written: [Bool], survivor: Int) {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-pins-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = PinStore(fileURL: storeURL)
        let writer = PinStoreWriter()

        let results = generations.map { generation in
            writer.write(
                [PinRecord(path: "/\(generation)", frame: .zero, alpha: 1, clickThrough: false)],
                generation: generation,
                to: store
            )
        }
        #expect(results == written)
        #expect(store.load().map(\.path) == ["/\(survivor)"])
    }

    @Test("Hide makes pins invisible without closing them")
    func hideDoesNotClose() throws {
        let (manager, storeURL) = makeManager()
        defer {
            manager.closeAll()
            try? FileManager.default.removeItem(at: storeURL)
        }
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }))
        manager.toggleHidden()
        #expect(manager.isHidden)
        #expect(manager.count == 1)
        #expect(pinPanels(showing: url).allSatisfy { !$0.isVisible })
        manager.toggleHidden()
        #expect(!manager.isHidden)
        #expect(pinPanels(showing: url).contains { $0.isVisible })
    }

    @Test("Middle-click closes a pin (CleanShot §11, §22.4)")
    func middleClickCloses() throws {
        let (manager, storeURL) = makeManager()
        defer {
            manager.closeAll()
            try? FileManager.default.removeItem(at: storeURL)
        }
        let url = try writeCapture(width: 400, height: 300)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.pin(url, copy: { _ in }, save: { _ in }))
        let panel = try #require(pinPanels(showing: url).first { $0.isVisible })
        panel.closeFromMiddleClick()
        #expect(manager.isEmpty)
    }

    /// This test's own pins. Other suites run on the main actor too, and their panels are
    /// in `NSApp.windows` whenever one of them is waiting on something.
    private func pinPanels(showing url: URL) -> [PinPanel] {
        NSApp.windows.compactMap { $0 as? PinPanel }.filter { $0.fileURL == url }
    }
}
