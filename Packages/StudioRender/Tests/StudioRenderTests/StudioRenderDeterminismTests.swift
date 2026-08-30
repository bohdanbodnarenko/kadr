import AVFoundation
import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// That a render is reproducible, and that it reports itself honestly (docs/09 U3.3).
///
/// Its own suite because it is a different question from "does the export work": these are
/// the properties the editor's preview depends on, and they fail in ways the functional
/// tests would pass straight through.
@Suite("Studio render determinism")
struct StudioRenderDeterminismTests {
    private typealias Media = StudioMediaFixtures
    private let sourceSize = CGSize(width: 320, height: 180)

    private var options: StudioRenderer.Options {
        .init(codec: .h264, frameRate: 30)
    }

    // MARK: - Determinism

    /// The frame-hash comparison docs/09 U3.3 asks for, at the level the claim is true.
    ///
    /// Two renders of one edit have to be the same movie, because the preview and the
    /// export read the same precomputed timeline and that promise is worthless if a render
    /// is not reproducible.
    ///
    /// What is deliberately *not* asserted is that the two files are byte-identical.
    /// VideoToolbox's H.264 encoder is multi-threaded and its rate control is not
    /// reproducible, so identical input frames encode to files differing by roughly one
    /// count in one byte in a hundred. Demanding equal bytes here would be a test of the
    /// encoder's mood, and it would be red on somebody's machine forever. The exact,
    /// byte-for-byte determinism of the composition — the part Kadr wrote — is asserted in
    /// the composer's own suite, before an encoder is anywhere near it.
    @Test("Rendering the same edit twice produces the same movie")
    func deterministicRender() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)

        var telemetry = InputTelemetry()
        telemetry.pointer = [
            PointerSample(time: 0, position: CGPoint(x: 40, y: 40)),
            PointerSample(time: 1, position: CGPoint(x: 280, y: 140))
        ]
        telemetry.clicks = [ClickEvent(time: 0.5, position: CGPoint(x: 160, y: 90))]

        var edit = Media.edit(
            zooms: [ZoomCue(start: 0.1, duration: 0.8, magnification: 2, anchor: .fixed(CGPoint(x: 160, y: 90)))],
            duration: 1
        )
        edit.showsClicks = true

        var renders: [[[UInt8]]] = []
        for attempt in 0 ..< 2 {
            let destination = folder.appendingPathComponent("out-\(attempt).mov")
            try await StudioRenderer().render(
                StudioRenderer.Source(
                    screen: movie,
                    telemetry: telemetry,
                    edit: edit,
                    pixelSize: sourceSize
                ),
                to: destination,
                options: options
            )
            try await renders.append(Media.frameBytes(of: destination))
        }

        #expect(renders[0].count == renders[1].count, "the two renders wrote different numbers of frames")
        #expect(!renders[0].isEmpty, "no frames were read back")
        for (index, pair) in zip(renders[0], renders[1]).enumerated() {
            let drift = Media.difference(pair.0, pair.1)
            // Measured rather than guessed. On an idle machine two encodes of identical
            // frames differ by 0.0–0.05; under a full parallel test run that rises to about
            // 0.6, because VideoToolbox's rate control is multi-threaded and contended. A
            // genuinely different picture — the same session at a different instant —
            // measures 48.6. Five sits an order of magnitude clear of both, and a tighter
            // threshold fails on a busy machine for no defect, which is how a test gets
            // deleted rather than fixed.
            #expect(drift < 5, "frame \(index) is a different picture (mean byte difference \(drift))")
        }
    }

    /// The other half of the claim: two *different* instants of a moving camera must not
    /// come out the same, or the test above would pass on a renderer that ignored time.
    @Test("A moving camera renders different frames as the render goes on")
    func framesChangeOverTime() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        let cue = ZoomCue(start: 0, duration: 1, magnification: 3, anchor: .fixed(CGPoint(x: 40, y: 90)))
        try await StudioRenderer().render(
            StudioRenderer.Source(screen: movie, edit: Media.edit(zooms: [cue], duration: 1), pixelSize: sourceSize),
            to: destination,
            options: options
        )

        let frames = try await Media.frameBytes(of: destination)
        let first = try #require(frames.first)
        let last = try #require(frames.last)
        // The measured value for this fixture is about 48, so ten is a floor rather than a
        // boundary — it asserts that the camera moved, not that it moved by some amount.
        #expect(Media.difference(first, last) > 10, "the camera did not move over the render")
    }

    // MARK: - Progress

    @Test("Progress runs forward and finishes at one")
    func progressReported() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        let recorder = ProgressRecorder()
        try await StudioRenderer().render(
            StudioRenderer.Source(screen: movie, edit: Media.edit(duration: 1), pixelSize: sourceSize),
            to: destination,
            options: options,
            progress: { recorder.record($0) }
        )
        let values = recorder.values
        #expect(values.count > 5, "progress was reported \(values.count) times")
        #expect(values.last == 1, "progress finished at \(values.last ?? -1)")
        // Monotonic, because a progress bar that goes backwards reads as a stall and is the
        // reason somebody cancels an export that was about to finish.
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards")
    }
}
