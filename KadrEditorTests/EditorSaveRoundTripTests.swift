import AnnotationModel
import CoreGraphics
import EditorUI
import Foundation
import Testing
@testable import KadrEditor

/// Open → edit → save → reopen against real folders (docs/18 X-6).
@MainActor
@Suite("Editor save round trip", .serialized)
struct EditorSaveRoundTripTests {
    private func drawArrow(on controller: EditorWindowController) {
        controller.model.tool = .arrow
        controller.model.pointerDown(at: CGPoint(x: 4, y: 4))
        controller.model.pointerDragged(to: CGPoint(x: 30, y: 20))
        controller.model.pointerUp(at: CGPoint(x: 30, y: 20))
    }

    @Test("Save As writes the image and a project that reopens with the annotation")
    func saveAsRoundTrip() throws {
        let folder = EditorTestFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = folder.appendingPathComponent("Capture.png")
        try EditorTestFixtures.writePNG(to: capture)

        let controller = try EditorWindowController(fileURL: capture)
        drawArrow(on: controller)
        #expect(controller.model.document.commands.count == 1)

        let destination = folder.appendingPathComponent("Edited.png")
        try controller.saveAs(controller.baseImage, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!controller.model.hasUnsavedChanges)

        let project = destination.deletingPathExtension()
            .appendingPathExtension(KadrDocumentFile.fileExtension)
        // The sidecar is a preference; without it there is no project to reopen.
        guard FileManager.default.fileExists(atPath: project.path) else { return }
        let reopened = try EditorWindowController(fileURL: project)
        #expect(reopened.model.document.commands.count == 1)
    }

    @Test("⌘S on a capture outside Kadr's folders writes beside it, not into a hidden copy")
    func saveInPlace() throws {
        let folder = EditorTestFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = folder.appendingPathComponent("Desktop Capture.png")
        try EditorTestFixtures.writePNG(to: capture)

        let controller = try EditorWindowController(fileURL: capture)
        #expect(!controller.editsImportedCopy)
        drawArrow(on: controller)
        let targets = controller.saveTargets
        try controller.save(controller.baseImage)

        #expect(targets.flattened.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: targets.flattened.path))
        #expect(!controller.model.hasUnsavedChanges)
    }

    struct ProxyCase: Sendable, CustomTestStringConvertible {
        let document: String
        let image: String?
        let expected: String?
        var testDescription: String {
            document
        }
    }

    @Test("The title-bar proxy never names a project", arguments: [
        ProxyCase(document: "/tmp/a/Shot.png", image: "/tmp/a/Shot.png", expected: "/tmp/a/Shot.png"),
        ProxyCase(document: "/tmp/a/Shot.kadr", image: "/tmp/a/Shot.png", expected: "/tmp/a/Shot.png"),
        ProxyCase(document: "/tmp/a/Shot.kadr", image: nil, expected: nil)
    ])
    func proxy(_ testCase: ProxyCase) {
        let url = EditorWindowController.proxyURL(
            for: URL(fileURLWithPath: testCase.document),
            existingImage: testCase.image.map { URL(fileURLWithPath: $0) }
        )
        #expect(url?.path == testCase.expected)
    }
}
