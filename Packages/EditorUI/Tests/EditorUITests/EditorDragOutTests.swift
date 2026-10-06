import AnnotationModel
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import EditorUI

/// Dragging the flattened image out of the editor (docs/18 ED-3).
@MainActor
@Suite("Editor drag-out")
struct EditorDragOutTests {
    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 80, height: 60), scale: 2)
        ))
    }

    @Test("No renderer, no drag")
    func noRenderer() {
        #expect(makeModel().flattenedImageItemProvider() == nil)
    }

    @Test("The drag offers a PNG under the capture's name, rendered on request")
    func offersRenderedPNG() async throws {
        let model = makeModel()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-drag-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var renders = 0
        model.flattenedDragName = "Shot"
        model.flattenedFileRenderer = {
            renders += 1
            return file
        }

        let provider = try #require(model.flattenedImageItemProvider())
        #expect(provider.registeredTypeIdentifiers == [UTType.png.identifier])
        #expect(provider.suggestedName == "Shot")
        #expect(renders == 0, "nothing renders until a receiver asks")

        let received: Bool = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, _ in
                continuation.resume(returning: url != nil)
            }
        }
        #expect(received)
        #expect(renders == 1)
    }
}
