import CoreGraphics
import Foundation
import ImageIO
import Shared

/// The growing strip shown while a scrolling capture is running (docs/03 §1.6).
///
/// Deliberately not the real stitch. The real one happens in the helper, once, when the
/// user stops; this is a cheap running sketch at a fraction of the width, so the user can
/// see that the capture is working and how much of the page they have covered. Frames are
/// downsampled on the way in through ImageIO, so the agent never decodes one at full size
/// (docs/04 §7 rule 2).
@MainActor
final class ScrollPreviewStrip {
    /// The preview's width in pixels. Small on purpose: this is a progress indicator.
    static let width = 200
    /// The tallest strip kept. Past this the top scrolls away — a preview of a very long
    /// page is not more useful for being taller, and it must not grow without bound.
    static let maximumHeight = 3000

    private(set) var image: CGImage?
    private var context: CGContext?
    private var contentHeight = 0
    private var scale: CGFloat = 1
    /// The thumbnail budget that gets the preview to `width` across. ImageIO measures the
    /// *longest* side, which on a tall capture is the height, so the number is scaled by
    /// the aspect ratio rather than being `width` itself.
    private var thumbnailMaxPixelSize = ScrollPreviewStrip.width

    /// Starts a new strip for frames of `frameSize`.
    func begin(frameSize: PixelSize) {
        reset()
        guard frameSize.width > 0, frameSize.height > 0 else { return }
        scale = CGFloat(Self.width) / CGFloat(frameSize.width)
        let longest = max(frameSize.width, frameSize.height)
        thumbnailMaxPixelSize = max(Self.width, Int((CGFloat(longest) * scale).rounded()))
        context = CGContext(
            data: nil,
            width: Self.width,
            height: Self.maximumHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    func reset() {
        context = nil
        image = nil
        contentHeight = 0
    }

    /// Adds the band a frame brought with it.
    ///
    /// - Parameters:
    ///   - band: rows of the frame to take, measured from its top.
    func append(frameAt url: URL, band: Range<Int>, frameHeight: Int) {
        guard let context, band.lowerBound < band.upperBound else { return }
        guard let thumbnail = downsample(url) else { return }

        let scaledFrame = CGFloat(frameHeight) * scale
        let bandHeight = max(1, Int((CGFloat(band.count) * scale).rounded()))
        let bandTop = CGFloat(band.lowerBound) * scale

        // Everything is measured from the top of the strip; the context counts from the
        // bottom, so the flip happens here and nowhere else.
        if contentHeight + bandHeight > Self.maximumHeight {
            scrollUp(by: contentHeight + bandHeight - Self.maximumHeight)
        }

        let bandBottom = CGFloat(Self.maximumHeight - contentHeight - bandHeight)
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: bandBottom, width: CGFloat(Self.width), height: CGFloat(bandHeight)))
        context.draw(thumbnail, in: CGRect(
            x: 0,
            y: bandBottom + CGFloat(bandHeight) - scaledFrame + bandTop,
            width: CGFloat(Self.width),
            height: scaledFrame
        ))
        context.restoreGState()

        contentHeight = min(contentHeight + bandHeight, Self.maximumHeight)
        image = context.makeImage().flatMap {
            $0.cropping(to: CGRect(
                x: 0,
                y: CGFloat(Self.maximumHeight - contentHeight),
                width: CGFloat(Self.width),
                height: CGFloat(contentHeight)
            ))
        }
    }

    /// Slides the strip up to make room, dropping the oldest rows.
    private func scrollUp(by rows: Int) {
        guard let context, let current = context.makeImage() else { return }
        context.clear(CGRect(x: 0, y: 0, width: Self.width, height: Self.maximumHeight))
        context.draw(current, in: CGRect(
            x: 0,
            y: CGFloat(rows),
            width: CGFloat(Self.width),
            height: CGFloat(Self.maximumHeight)
        ))
        contentHeight = max(0, contentHeight - rows)
    }

    /// Reads the frame back at preview size, never at capture size.
    private func downsample(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
