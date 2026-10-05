import AnnotationModel
import CoreGraphics
import Foundation
import HistoryKit
import ImageIO
import Shared
import Testing
import UniformTypeIdentifiers
@testable import Kadr

/// Adding a saved project to the capture library (docs/03 §5, docs/06 M24).
@MainActor
@Suite("Project ingest")
struct ProjectIngestTests {
    private func makePNG(width: Int = 40, height: Int = 20) -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not create a test bitmap")
        }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Could not create a test image")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            fatalError("Could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Could not encode the test PNG")
        }
        return data as Data
    }

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-ingest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A .kadr project is recognized as a project and keeps its pixel size")
    func projectDraft() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = makePNG()
        let document = AnnotationDocument(
            baseImage: BaseImageReference(size: CGSize(width: 20, height: 10), scale: 2)
        )
        let url = directory.appendingPathComponent("shot.kadr")
        try KadrDocumentFile.write(
            KadrDocumentFile.Contents(document: document, baseImagePNG: png),
            to: url
        )

        let draft = try #require(ProjectIngest().draft(for: url))
        #expect(draft.kind == .project)
        #expect(draft.pixelSize.width == 40)
        #expect(draft.pixelSize.height == 20)
        #expect(draft.originalFilename == "shot.kadr")

        // A zip cannot be thumbnailed, so the base image is staged as one.
        let thumbnailSource = try #require(draft.thumbnailSourceURL)
        #expect(FileManager.default.fileExists(atPath: thumbnailSource.path))
        try? FileManager.default.removeItem(at: thumbnailSource)
    }

    @Test("A plain image is recognized as an image, at its real size")
    func imageDraft() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("shot.png")
        try makePNG(width: 64, height: 32).write(to: url)

        let draft = try #require(ProjectIngest().draft(for: url))
        #expect(draft.kind == .image)
        #expect(draft.pixelSize.width == 64)
        #expect(draft.pixelSize.height == 32)
        #expect(draft.thumbnailSourceURL == nil, "an image thumbnails itself")
    }

    @Test("A file that is not there produces nothing")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-absent-\(UUID().uuidString).png")
        #expect(ProjectIngest().draft(for: url) == nil)
    }

    @Test("A .kadr that is not really a project is refused rather than half-ingested")
    func corruptProject() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("broken.kadr")
        try Data("not a zip".utf8).write(to: url)
        #expect(ProjectIngest().draft(for: url) == nil)
    }

    @Test("Projects reopen in the editor rather than as an overlay card")
    func projectsOpenInTheEditor() {
        #expect(HistoryItemKind.project.opensInEditor)
        #expect(!HistoryItemKind.image.opensInEditor)
        // And the text indexer leaves them alone: the capture inside is indexed already.
        #expect(!HistoryItemKind.project.isReadable)
        #expect(HistoryItemKind.image.isReadable)
    }
}
