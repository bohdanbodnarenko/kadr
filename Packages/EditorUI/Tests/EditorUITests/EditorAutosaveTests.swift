import AnnotationModel
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EditorUI

/// Unsaved work in the editor (docs/03 §3, docs/07 M7, docs/09 U0.5).
///
/// The review's finding: closing an editor window discarded every annotation with no
/// prompt, and the `.kadr` write path existed but nothing reached it. Two halves: the
/// window has to know whether there is anything to lose, and something has to hold a copy
/// while the user works.
@MainActor
@Suite("Editor autosave")
struct EditorAutosaveTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-autosave-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel() -> EditorDocumentModel {
        EditorDocumentModel(document: AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 200, height: 100), scale: 2)
        ))
    }

    private func makeContents(_ document: AnnotationDocument) -> KadrDocumentFile.Contents {
        KadrDocumentFile.Contents(document: document, baseImagePNG: Self.onePixelPNG)
    }

    /// A real one-pixel PNG, so `KadrDocumentFile` has something valid to carry.
    private static let onePixelPNG: Data = {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context?.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    // MARK: - Knowing there is something to lose

    @Test("A freshly opened capture has nothing to save")
    func freshDocumentIsClean() {
        #expect(!makeModel().hasUnsavedChanges)
    }

    @Test("Drawing something makes the window dirty")
    func drawingMakesItDirty() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 60, y: 40))
        model.pointerUp(at: CGPoint(x: 60, y: 40))

        #expect(model.hasUnsavedChanges)
    }

    /// Undoing back to the start is clean again — the user has nothing to lose, so the
    /// window must stop asking.
    @Test("Undoing back to where it started is clean again")
    func undoBackToCleanIsClean() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 60, y: 40))
        model.pointerUp(at: CGPoint(x: 60, y: 40))
        model.undo()

        #expect(!model.hasUnsavedChanges)
    }

    @Test("Saving marks the work as safe")
    func savingClearsTheFlag() {
        let model = makeModel()
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 10, y: 10))
        model.pointerDragged(to: CGPoint(x: 60, y: 40))
        model.pointerUp(at: CGPoint(x: 60, y: 40))
        model.markSaved()

        #expect(!model.hasUnsavedChanges)

        // …and editing after a save makes it dirty again.
        model.tool = .shape
        model.pointerDown(at: CGPoint(x: 80, y: 10))
        model.pointerDragged(to: CGPoint(x: 120, y: 40))
        model.pointerUp(at: CGPoint(x: 120, y: 40))
        #expect(model.hasUnsavedChanges)
    }

    @Test("Rotating the capture makes the window dirty")
    func rotatingMakesItDirty() {
        let model = makeModel()
        #expect(!model.hasUnsavedChanges)
        model.rotateClockwise()
        #expect(model.hasUnsavedChanges)
        model.markSaved()
        #expect(!model.hasUnsavedChanges)
        model.flipHorizontal()
        #expect(model.hasUnsavedChanges)
    }

    @Test("Restored work counts as unsaved, because it is")
    func restoredWorkIsDirty() {
        let model = makeModel()
        var recovered = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 200, height: 100), scale: 2)
        )
        recovered.add(.shape(ShapeSpec(rect: CGRect(x: 0, y: 0, width: 10, height: 10))))
        model.replaceDocument(recovered)

        #expect(model.hasUnsavedChanges)
    }

    // MARK: - Holding a copy

    @Test("An autosave round-trips the annotations")
    func autosaveRoundTrips() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/Captures/Screenshot.png")

        var document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 200, height: 100), scale: 2)
        )
        document.add(.shape(ShapeSpec(rect: CGRect(x: 4, y: 5, width: 30, height: 20))))
        try autosave.write(makeContents(document), for: capture)

        #expect(autosave.hasAutosave(for: capture))
        let recovered = try #require(autosave.read(for: capture))
        #expect(recovered.document.commands == document.commands)
    }

    @Test("Two captures with the same filename do not share an autosave")
    func namesDoNotCollide() {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)

        let first = autosave.url(for: URL(fileURLWithPath: "/one/Shot.png"))
        let second = autosave.url(for: URL(fileURLWithPath: "/two/Shot.png"))
        #expect(first != second)
    }

    @Test("The same capture always maps to the same autosave")
    func nameIsStable() {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/one/./Shot.png")

        #expect(autosave.url(for: capture) == autosave.url(for: URL(fileURLWithPath: "/one/Shot.png")))
    }

    @Test("Discarding leaves nothing behind")
    func discardRemovesEverything() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/Captures/Screenshot.png")

        try autosave.write(makeContents(AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 10, height: 10))
        )), for: capture)
        autosave.discard(for: capture)

        #expect(!autosave.hasAutosave(for: capture))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty,
            "the note of where it came from must go too"
        )
    }

    @Test("Nothing to read when nothing was written")
    func readingNothing() {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        #expect(autosave.read(for: URL(fileURLWithPath: "/nope.png")) == nil)
    }

    // MARK: - docs/18 ED-10: the base image once, the annotations every time

    @Test("The base image is written once; later saves rewrite only the annotations")
    func baseWrittenOnce() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/Captures/Screenshot.png")
        var document = AnnotationDocument(baseImage: BaseImageReference(size: CGSize(width: 10, height: 10)))
        try autosave.write(makeContents(document), for: capture)

        let base = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".base.png") })
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: base.path)

        document.add(.shape(ShapeSpec(rect: CGRect(x: 1, y: 1, width: 4, height: 4))))
        try autosave.write(makeContents(document), for: capture)

        let modified = try FileManager.default.attributesOfItem(atPath: base.path)[.modificationDate] as? Date
        #expect(modified == past)
        #expect(autosave.read(for: capture)?.document.commands == document.commands)
    }

    @Test("A rotation survives the autosave")
    func orientationSurvives() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/Captures/Screenshot.png")
        var document = AnnotationDocument(baseImage: BaseImageReference(size: CGSize(width: 10, height: 10)))
        document.rotateClockwise()
        try autosave.write(makeContents(document), for: capture)

        #expect(autosave.read(for: capture)?.document.orientation == document.orientation)
    }

    @Test("An autosave from an earlier build is still offered")
    func legacyAutosaveIsRead() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/Captures/Screenshot.png")
        var document = AnnotationDocument(baseImage: BaseImageReference(size: CGSize(width: 10, height: 10)))
        document.add(.shape(ShapeSpec(rect: CGRect(x: 1, y: 1, width: 4, height: 4))))
        let legacy = autosave.url(for: capture).deletingPathExtension()
            .appendingPathExtension(KadrDocumentFile.fileExtension)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try KadrDocumentFile.write(makeContents(document), to: legacy)

        #expect(autosave.hasAutosave(for: capture))
        #expect(autosave.read(for: capture)?.document.commands == document.commands)
    }

    @Test("An unreadable autosave is dropped rather than offered")
    func corruptAutosaveIsDropped() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let capture = URL(fileURLWithPath: "/Captures/Screenshot.png")

        try Data("not a kadr file".utf8).write(to: autosave.url(for: capture))
        #expect(autosave.read(for: capture) == nil)
        #expect(!autosave.hasAutosave(for: capture))
    }

    /// A deleted capture must not leave its annotations sitting in Application Support.
    @Test("Autosaves for captures that are gone are swept")
    func orphansAreSwept() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let gone = URL(fileURLWithPath: "/Captures/Deleted.png")
        let kept = URL(fileURLWithPath: "/Captures/Still Here.png")

        let contents = makeContents(AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 10, height: 10))
        ))
        try autosave.write(contents, for: gone)
        try autosave.write(contents, for: kept)

        let removed = autosave.sweepOrphans { $0.lastPathComponent == "Still Here.png" }
        #expect(removed == 1)
        #expect(!autosave.hasAutosave(for: gone))
        #expect(autosave.hasAutosave(for: kept))
    }

    @Test("Sweeping an empty or missing folder is harmless")
    func sweepingNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-absent-\(UUID().uuidString)")
        #expect(EditorAutosave(directory: missing).sweepOrphans() == 0)
    }

    @Test("The launch recovery list names captures with work, and only those that exist")
    func pendingRecoveries() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let autosave = EditorAutosave(directory: folder)
        let kept = folder.appendingPathComponent("b-kept.png")
        let gone = folder.appendingPathComponent("a-gone.png")
        let contents = makeContents(makeModel().document)
        try autosave.write(contents, for: kept)
        try autosave.write(contents, for: gone)

        let pending = autosave.pendingRecoveries { $0.lastPathComponent != gone.lastPathComponent }

        #expect(pending.map(\.lastPathComponent) == ["b-kept.png"])
        autosave.discard(for: kept)
        #expect(autosave.pendingRecoveries { _ in true }.map(\.lastPathComponent) == ["a-gone.png"])
    }
}
