import CoreGraphics
import CoreVideo
import Foundation
import Shared
import Testing
@testable import RecordingCore

/// Overlays over an HDR frame (docs/11 S0.5, S1).
///
/// HDR and click halos are two independent switches in the same settings pane. The engine
/// moves the stream to `ARGB2101010LEPacked` for the first; the compositor described every
/// buffer as 8 bits per component. Both formats are four bytes per pixel, so `CGContext`
/// *accepted* the wrong description and reinterpreted 10-bit data as 8888 — every pixel it
/// touched, on a path nothing unusual is needed to reach.
@Suite("HDR overlay compositing")
struct HDROverlayTests {
    private static let width = 64
    private static let height = 40

    private func makeBuffer(format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.width,
            Self.height,
            format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            fatalError("Could not allocate a test pixel buffer")
        }
        return buffer
    }

    /// The two formats a recording can actually produce are both described, and correctly.
    @Test(
        "The formats a recording produces are both understood",
        arguments: [
            (kCVPixelFormatType_32BGRA, 8),
            (kCVPixelFormatType_ARGB2101010LEPacked, 10)
        ]
    )
    func knownFormatsAreDescribed(format: OSType, bits: Int) throws {
        let layout = try #require(FrameCompositor.BitmapLayout(pixelFormat: format))
        #expect(layout.bitsPerComponent == bits)
    }

    /// The description has to be one CoreGraphics will actually accept over a real buffer of
    /// that format — a table of constants that no context can be built from would be a
    /// different way of drawing nothing.
    @Test("A context can be built over a standard-range frame")
    func contextCanBeBuiltForBGRA() throws {
        let buffer = makeBuffer(format: kCVPixelFormatType_32BGRA)
        let layout = try #require(FrameCompositor.BitmapLayout(pixelFormat: kCVPixelFormatType_32BGRA))

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try CGContext(
            data: #require(CVPixelBufferGetBaseAddress(buffer)),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: layout.bitsPerComponent,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: layout.bitmapInfo
        )
        #expect(context != nil)
    }

    /// An unknown format is refused rather than guessed at. This is the whole fix: the old
    /// code had no notion of "a format I do not recognise", so it treated every one of them
    /// as 8-bit BGRA — which is not a wrong branch but an absent concept.
    @Test("An unrecognised format is refused")
    func unknownFormatIsRefused() {
        #expect(FrameCompositor.BitmapLayout(pixelFormat: kCVPixelFormatType_420YpCbCr8Planar) == nil)
        #expect(FrameCompositor.BitmapLayout(pixelFormat: kCVPixelFormatType_OneComponent8) == nil)
    }

    /// The guarantee that actually matters: an HDR frame comes out of the compositor exactly
    /// as it went in.
    ///
    /// Not "the overlay is drawn" — it deliberately is not. `CGBitmapContext` has no
    /// representation for `ARGB2101010LEPacked` at all; every combination of
    /// bits-per-component, alpha and byte order CoreGraphics accepts was tried and none
    /// describes it, which is why the fix is at the other end: an HDR recording bakes
    /// nothing and the studio draws the overlays at export, where they stay editable
    /// anyway. What must never happen again is the frame being *altered* on the way past.
    @Test("An HDR frame is passed through untouched rather than corrupted")
    func hdrFrameIsLeftAlone() throws {
        let buffer = makeBuffer(format: kCVPixelFormatType_ARGB2101010LEPacked)
        CVPixelBufferLockBaseAddress(buffer, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let total = rowBytes * Self.height
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x5A, total)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let overlay = RecordingOverlay(clicks: [ClickPulse(
            position: CGPoint(x: Self.width / 2, y: Self.height / 2),
            progress: 0.3
        )])
        FrameCompositor().draw(overlay, into: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let raw = UnsafeRawBufferPointer(start: base, count: total)
        #expect(raw.allSatisfy { $0 == 0x5A }, "the compositor rewrote an HDR frame it cannot address")
    }
}
