import AppKit
import Foundation
import StudioSession
import SwiftUI
import Testing
@testable import EditorUI

/// The studio's bottom bar keeps its groups apart at every width (docs/09 U3.3).
@MainActor
@Suite("Studio transport layout")
struct StudioTransportLayoutTests {
    private func model() throws -> (StudioDocumentModel, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = RecordingSession.create(in: folder, named: "session")
        try session.create()
        try Data("footage".utf8).write(to: session.screenURL)
        try SessionDocument(session: session).write(CaptureManifest(
            pixelSize: CGSize(width: 1920, height: 1080),
            duration: 10,
            hasBakedCursor: true
        ))
        return try (#require(StudioDocumentModel(session: session)), folder)
    }

    private func idealSize(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    @Test("The compact bar is much narrower, and neither grows taller than one row")
    func compactIsNarrower() throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        let regular = idealSize(StudioTransportBar(model: model))
        let compact = idealSize(StudioTransportBar(model: model, density: .compact))
        #expect(compact.width < regular.width * 0.7)
        #expect(regular.height == 32)
        #expect(compact.height == 32)
    }

    @Test("The regular bar needs the width of its three groups side by side")
    func regularDoesNotOverlap() throws {
        let (model, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Its old ZStack reported only the widest group, so a parent happily gave it less
        // room than the three groups need and they drew over each other.
        let regular = idealSize(StudioTransportBar(model: model))
        #expect(regular.width > 560)
    }
}
