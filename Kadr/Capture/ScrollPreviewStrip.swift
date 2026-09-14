import CoreGraphics
import Foundation
import ImageIO
import Shared

/// The growing strip shown while a scrolling capture is running (docs/03 §1.6).
///
/// Deliberately not the real stitch. The real one happens in the helper, once, when the
/// user stops; this is a cheap running sketch at a fraction of the capture size, so the
/// user can see that the capture is working and how much of the page they have covered.
/// Frames are downsampled on the way in through ImageIO, so the agent never decodes one at
/// full size (docs/04 §7 rule 2).
@MainActor
final class ScrollPreviewStrip {
    /// The preview's fixed extent in pixels along the short axis.
    static let fixedExtent = 200
    /// The longest strip kept. Past this the oldest content scrolls away.
    static let maximumExtent = 3000

    private(set) var image: CGImage?
    private var context: CGContext?
    private var contentExtent = 0
    private var scale: CGFloat = 1
    private var axis: ScrollAxis = .vertical
    private var thumbnailMaxPixelSize = ScrollPreviewStrip.fixedExtent

    /// Starts a new strip for frames of `frameSize`.
    func begin(frameSize: PixelSize, axis: ScrollAxis = .vertical) {
        reset()
        self.axis = axis
        guard frameSize.width > 0, frameSize.height > 0 else { return }

        switch axis {
        case .vertical:
            scale = CGFloat(Self.fixedExtent) / CGFloat(frameSize.width)
            let longest = max(frameSize.width, frameSize.height)
            thumbnailMaxPixelSize = max(Self.fixedExtent, Int((CGFloat(longest) * scale).rounded()))
            context = CGContext(
                data: nil,
                width: Self.fixedExtent,
                height: Self.maximumExtent,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        case .horizontal:
            scale = CGFloat(Self.fixedExtent) / CGFloat(frameSize.height)
            let longest = max(frameSize.width, frameSize.height)
            thumbnailMaxPixelSize = max(Self.fixedExtent, Int((CGFloat(longest) * scale).rounded()))
            context = CGContext(
                data: nil,
                width: Self.maximumExtent,
                height: Self.fixedExtent,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
    }

    func reset() {
        context = nil
        image = nil
        contentExtent = 0
    }

    /// Adds the band a frame brought with it.
    ///
    /// - Parameters:
    ///   - band: rows (vertical) or columns (horizontal) of the frame to take.
    ///   - frameExtent: the frame's height for vertical capture, width for horizontal.
    func append(frameAt url: URL, band: Range<Int>, frameExtent: Int) {
        guard let context, band.lowerBound < band.upperBound else { return }
        guard let thumbnail = downsample(url) else { return }

        switch axis {
        case .vertical:
            appendVertical(
                thumbnail: thumbnail,
                band: band,
                frameHeight: frameExtent,
                in: context
            )
        case .horizontal:
            appendHorizontal(
                thumbnail: thumbnail,
                band: band,
                frameWidth: frameExtent,
                in: context
            )
        }
    }

    private func appendVertical(
        thumbnail: CGImage,
        band: Range<Int>,
        frameHeight: Int,
        in context: CGContext
    ) {
        let scaledFrame = CGFloat(frameHeight) * scale
        let bandHeight = max(1, Int((CGFloat(band.count) * scale).rounded()))
        let bandTop = CGFloat(band.lowerBound) * scale

        if contentExtent + bandHeight > Self.maximumExtent {
            scrollVerticalUp(by: contentExtent + bandHeight - Self.maximumExtent, in: context)
        }

        let bandBottom = CGFloat(Self.maximumExtent - contentExtent - bandHeight)
        context.saveGState()
        context.clip(to: CGRect(
            x: 0,
            y: bandBottom,
            width: CGFloat(Self.fixedExtent),
            height: CGFloat(bandHeight)
        ))
        context.draw(thumbnail, in: CGRect(
            x: 0,
            y: bandBottom + CGFloat(bandHeight) - scaledFrame + bandTop,
            width: CGFloat(Self.fixedExtent),
            height: scaledFrame
        ))
        context.restoreGState()

        contentExtent = min(contentExtent + bandHeight, Self.maximumExtent)
        image = context.makeImage().flatMap {
            $0.cropping(to: CGRect(
                x: 0,
                y: CGFloat(Self.maximumExtent - contentExtent),
                width: CGFloat(Self.fixedExtent),
                height: CGFloat(contentExtent)
            ))
        }
    }

    private func appendHorizontal(
        thumbnail: CGImage,
        band: Range<Int>,
        frameWidth: Int,
        in context: CGContext
    ) {
        let scaledFrame = CGFloat(frameWidth) * scale
        let bandWidth = max(1, Int((CGFloat(band.count) * scale).rounded()))
        let bandLeading = CGFloat(band.lowerBound) * scale

        if contentExtent + bandWidth > Self.maximumExtent {
            scrollHorizontalLeft(by: contentExtent + bandWidth - Self.maximumExtent, in: context)
        }

        let bandLeadingX = CGFloat(contentExtent)
        context.saveGState()
        context.clip(to: CGRect(
            x: bandLeadingX,
            y: 0,
            width: CGFloat(bandWidth),
            height: CGFloat(Self.fixedExtent)
        ))
        context.draw(thumbnail, in: CGRect(
            x: bandLeadingX + bandLeading - scaledFrame,
            y: 0,
            width: scaledFrame,
            height: CGFloat(Self.fixedExtent)
        ))
        context.restoreGState()

        contentExtent = min(contentExtent + bandWidth, Self.maximumExtent)
        image = context.makeImage().flatMap {
            $0.cropping(to: CGRect(
                x: CGFloat(Self.maximumExtent - contentExtent),
                y: 0,
                width: CGFloat(contentExtent),
                height: CGFloat(Self.fixedExtent)
            ))
        }
    }

    private func scrollVerticalUp(by rows: Int, in context: CGContext) {
        guard let current = context.makeImage() else { return }
        context.clear(CGRect(x: 0, y: 0, width: Self.fixedExtent, height: Self.maximumExtent))
        context.draw(current, in: CGRect(
            x: 0,
            y: CGFloat(rows),
            width: CGFloat(Self.fixedExtent),
            height: CGFloat(Self.maximumExtent)
        ))
        contentExtent = max(0, contentExtent - rows)
    }

    private func scrollHorizontalLeft(by columns: Int, in context: CGContext) {
        guard let current = context.makeImage() else { return }
        context.clear(CGRect(x: 0, y: 0, width: Self.maximumExtent, height: Self.fixedExtent))
        context.draw(current, in: CGRect(
            x: CGFloat(columns),
            y: 0,
            width: CGFloat(Self.maximumExtent),
            height: CGFloat(Self.fixedExtent)
        ))
        contentExtent = max(0, contentExtent - columns)
    }

    private func downsample(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// Backward-compatible names for existing tests.
extension ScrollPreviewStrip {
    static var width: Int {
        fixedExtent
    }

    static var maximumHeight: Int {
        maximumExtent
    }
}
