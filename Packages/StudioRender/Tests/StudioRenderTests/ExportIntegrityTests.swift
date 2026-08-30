import AVFoundation
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// A render that stops early must say so (docs/11 S0.4, S1 test 4).
///
/// `copyNextSampleBuffer()` returns nil for two entirely different things — the track
/// ended, or the reader died — and the render loop used to treat both as "done". A reader
/// that failed at minute seven exited cleanly, the writer finalised a well-formed
/// seven-minute file, and `StudioDocumentModel.export` wrote a `RenderStamp` blessing it as
/// the export of a ten-minute recording. Silent truncation with a certificate attached.
@Suite("Export integrity")
struct ExportIntegrityTests {
    private typealias Media = StudioMediaFixtures

    private var options: StudioRenderer.Options {
        .init(codec: .h264, frameRate: 30)
    }

    // MARK: - Why the reader stopped

    /// `.completed` is the only status that means "there was nothing more to read", and it
    /// has to keep passing — a check that rejected the ordinary ending would fail every
    /// export in the app.
    @Test("A reader that reached the end passes")
    func completedReaderPasses() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let asset = AVURLAsset(url: movie)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        while output.copyNextSampleBuffer() != nil {}

        #expect(reader.status == .completed)
        #expect(throws: Never.self) {
            try StudioRenderer().check(reader, expecting: 1)
        }
    }

    /// A reader that has not been started yet is not evidence of anything, and treating it
    /// as success would let a render that never read a frame report one.
    @Test("A reader that never ran is a failure, not a pass")
    func unstartedReaderIsAFailure() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let reader = try AVAssetReader(asset: AVURLAsset(url: movie))

        #expect(throws: (any Error).self) {
            try StudioRenderer().check(reader, expecting: 1)
        }
    }

    /// A cancelled reader looks exactly like a finished one from the loop's point of view:
    /// the next sample buffer is nil either way.
    @Test("A cancelled reader fails the render rather than truncating it")
    func cancelledReaderIsAFailure() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let asset = AVURLAsset(url: movie)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        reader.add(AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        #expect(reader.startReading())
        reader.cancelReading()

        #expect(throws: StudioRenderer.RenderError.cancelled) {
            try StudioRenderer().check(reader, expecting: 1)
        }
    }

    // MARK: - End to end

    /// The whole point, through the real render path.
    ///
    /// The damage is confined to the `mdat` payload and deliberately leaves `ftyp` and
    /// `moov` intact, which took three attempts to get right: corrupting the tail of the
    /// file destroys the index instead, the asset then has no video track at all, and the
    /// render fails before the loop it is supposed to be testing ever runs. A test that
    /// throws for the wrong reason looks exactly like a test that works.
    ///
    /// Measured against the unfixed code, this fixture renders 53 of the recording's 180
    /// frames and reports a successful six-second export.
    @Test("Footage that goes bad partway through fails the export")
    func corruptFootageFailsTheExport() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 6, in: folder)
        try damageMediaData(of: movie)

        let destination = folder.appendingPathComponent("out.mov")
        let source = StudioRenderer.Source(
            screen: movie,
            telemetry: InputTelemetry(),
            edit: Media.edit(duration: 6),
            pixelSize: CGSize(width: 320, height: 180)
        )

        var thrown: (any Error)?
        do {
            _ = try await StudioRenderer().render(source, to: destination, options: options)
        } catch {
            thrown = error
        }

        #expect(thrown != nil, "damaged footage exported as if it were whole")
        #expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "a failed read left a truncated movie at the destination"
        )
    }

    /// Overwrites the back two-thirds of a movie's sample data, leaving the container
    /// headers alone so the asset still loads and still promises its full length.
    private func damageMediaData(of movie: URL) throws {
        let bytes = try Data(contentsOf: movie)
        var offset = 0
        var mediaData: Range<Int>?
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            if String(bytes: bytes[offset + 4 ..< offset + 8], encoding: .ascii) == "mdat" {
                mediaData = (offset + 8) ..< (offset + length)
                break
            }
            guard length >= 8 else { break }
            offset += length
        }
        let media = try #require(mediaData, "the fixture is not a QuickTime file with an mdat atom")

        var damaged = bytes
        let from = media.lowerBound + media.count / 3
        damaged.replaceSubrange(
            from ..< media.upperBound,
            with: Data(repeating: 0xFF, count: media.upperBound - from)
        )
        try damaged.write(to: movie)
    }

    /// The guarantee that matters most, stated on its own: a render that finishes writes a
    /// file, and a render that does not writes nothing.
    @Test("A destination is either the whole export or absent")
    func destinationIsAllOrNothing() async throws {
        let folder = Media.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Media.makeMovie(seconds: 1, in: folder)
        let destination = folder.appendingPathComponent("out.mov")

        let output = try await StudioRenderer().render(
            StudioRenderer.Source(
                screen: movie,
                telemetry: InputTelemetry(),
                edit: Media.edit(duration: 1),
                pixelSize: CGSize(width: 320, height: 180)
            ),
            to: destination,
            options: options
        )
        #expect(output.frameCount > 0)

        let written = AVURLAsset(url: destination)
        let duration = try await written.load(.duration).seconds
        #expect(duration > 0.5, "the export finished but wrote less than the recording")
    }
}
