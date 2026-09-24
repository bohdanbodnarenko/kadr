import AnnotationModel
import AppKit
import Testing
@testable import EditorUI

@MainActor
@Suite("Canvas drops (T-ED-5)")
struct CanvasDropTests {
    private func makeCanvas() throws -> AnnotationCanvasView {
        let model = EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 40, height: 30), scale: 1)
        ))
        let context = try #require(CGContext(
            data: nil,
            width: 40,
            height: 30,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try AnnotationCanvasView(model: model, baseImage: #require(context.makeImage()))
    }

    @Test("The canvas registers for files, image data and file promises")
    func registersDragTypes() throws {
        let registered = try Set(makeCanvas().registeredDraggedTypes)
        #expect(registered.contains(.fileURL))
        #expect(registered.contains(.png))
        #expect(registered.contains(.tiff))
        for promise in NSFilePromiseReceiver.readableDraggedTypes {
            #expect(registered.contains(NSPasteboard.PasteboardType(promise)))
        }
    }

    @Test("A written promise file becomes PNG data with its pixel size")
    func promisedFileReads() throws {
        let context = try #require(CGContext(
            data: nil,
            width: 12,
            height: 7,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let drop = try #require(AnnotationCanvasView.image(at: url))
        #expect(drop.pixelSize == CGSize(width: 12, height: 7))
        #expect(AnnotationCanvasView.image(at: url.appendingPathExtension("missing")) == nil)
    }
}
