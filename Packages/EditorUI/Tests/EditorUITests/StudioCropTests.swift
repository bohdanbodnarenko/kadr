import AnnotationModel
import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import EditorUI

@MainActor
@Suite("Studio crop")
struct StudioCropTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-crop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(in folder: URL) throws -> StudioDocumentModel {
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return try #require(StudioDocumentModel(session: session))
    }

    @Test("A 16:9 image letterboxed in a square sits in the middle")
    func fittedRectCentres() {
        let fitted = StudioCropGeometry.fittedImageRect(
            image: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 400, height: 400)
        )
        #expect(abs(fitted.width - 400) < 0.001)
        #expect(abs(fitted.height - 225) < 0.001)
        #expect(abs(fitted.minY - 87.5) < 0.001)
    }

    @Test("A normalised crop maps onto the fitted image and back")
    func roundTrip() {
        let fitted = CGRect(x: 10, y: 20, width: 200, height: 100)
        let crop = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
        let view = StudioCropGeometry.viewRect(forNormalized: crop, inFitted: fitted)
        let back = StudioCropGeometry.normalized(view, inFitted: fitted)
        #expect(abs(back.minX - crop.minX) < 0.001)
        #expect(abs(back.minY - crop.minY) < 0.001)
        #expect(abs(back.width - crop.width) < 0.001)
        #expect(abs(back.height - crop.height) < 0.001)
    }

    @Test("Done commits the working crop; Cancel leaves the edit alone")
    func applyAndCancel() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)

        studio.beginCrop()
        #expect(studio.isCropping)
        studio.workingCrop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        studio.cancelCrop()
        #expect(!studio.isCropping)
        #expect(studio.edit.cropRect == nil)

        studio.beginCrop()
        studio.workingCrop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        studio.applyCrop()
        #expect(!studio.isCropping)
        let crop = try #require(studio.edit.cropRect)
        #expect(abs(crop.minX - 0.1) < 0.001)
        #expect(abs(crop.width - 0.8) < 0.001)
    }

    @Test("A full-frame crop is stored as no crop")
    func fullFrameIsNil() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = try model(in: folder)
        studio.beginCrop()
        studio.workingCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
        studio.applyCrop()
        #expect(studio.edit.cropRect == nil)
    }
}
