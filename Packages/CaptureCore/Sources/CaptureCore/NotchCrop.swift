import CoreGraphics
import Foundation
import os
import Shared

/// Crops the MacBook notch strip from a fullscreen still (CleanShot 4.6).
///
/// A notched display's fullscreen screenshot includes the black camera bar. Area
/// captures, windowed shots, and anything that does not cover the top of the
/// display are left alone. The pixel crop only runs when the bitmap still matches
/// the capture's geometry — a window that has already been padded onto a backdrop
/// is a different image, and slicing its top would take padding, not the notch.
///
/// The strip is only removed when it is actually empty black. Cropping whenever
/// the capture covers the top of a notched display would cut the visible menu bar
/// from every fullscreen shot of an app that covers the display (docs/03 §1.3,
/// docs/16 CAP-1).
public enum NotchCrop {
    /// Channels at or below this count as black.
    public static let channelThreshold: UInt8 = 14
    /// Fraction of non-black pixels that still counts as empty (0.2 %).
    public static let maxNonBlackFraction = 0.002
    /// Extra rows removed after a successful empty-strip probe, to catch a leftover hairline.
    public static let extraTrimRows = 2

    /// Crops `capture` when it is a fullscreen still of a notched display whose
    /// camera strip is empty black.
    public static func apply(
        _ capture: Capture,
        enabled: Bool,
        topInsetPoints: CGFloat,
        displayFrame: DisplayRect
    ) -> Capture {
        guard enabled, topInsetPoints > 0 else { return capture }
        guard includesNotchStrip(capture, displayFrame: displayFrame) else { return capture }
        guard pixelSizeMatchesGeometry(capture) else { return capture }

        let topPixels = Int((topInsetPoints * capture.metadata.scale.factor).rounded())
        // Half the shot, not a fifth: a 20 px notch on a 100 px test image is 20 %,
        // and a real MacBook notch is a few percent of the display. A menu-bar-only
        // strip is still refused because the inset would swallow most of it.
        guard topPixels > 0, topPixels < capture.image.height / 2 else { return capture }
        guard stripIsEmpty(capture.image, rows: topPixels) else { return capture }

        let signposter = KadrLog.signposter(.capture)
        let interval = signposter.beginInterval("notchCrop")
        defer { signposter.endInterval("notchCrop", interval) }

        let cropRows = min(topPixels + extraTrimRows, capture.image.height - 1)
        let crop = CGRect(
            x: 0,
            y: cropRows,
            width: capture.image.width,
            height: capture.image.height - cropRows
        )
        guard let cropped = capture.image.cropping(to: crop) else { return capture }

        let insetPoints = CGFloat(cropRows) / capture.metadata.scale.factor
        let rect = capture.metadata.pointRect
        return Capture(
            image: cropped,
            metadata: CaptureMetadata(
                source: capture.metadata.source,
                displayID: capture.metadata.displayID,
                scale: capture.metadata.scale,
                pointRect: DisplayRect(
                    x: rect.minX,
                    y: rect.minY + insetPoints,
                    width: rect.width,
                    height: rect.height - insetPoints
                ),
                pixelSize: PixelSize(width: cropped.width, height: cropped.height),
                colorSpaceName: cropped.colorSpace?.name as String? ?? capture.metadata.colorSpaceName,
                frontmostApp: capture.metadata.frontmostApp,
                windowTitle: capture.metadata.windowTitle,
                capturedAt: capture.metadata.capturedAt
            )
        )
    }

    /// True when the top `rows` of `image` are empty black.
    ///
    /// Draws only the strip into an 8-bit RGBA buffer and exits as soon as non-black
    /// pixels pass `maxNonBlack`. Pure, so it can be table-tested without a display.
    public static func stripIsEmpty(
        _ image: CGImage,
        rows: Int,
        channelThreshold: UInt8 = channelThreshold,
        maxNonBlack: Double = maxNonBlackFraction
    ) -> Bool {
        guard rows > 0, rows < image.height else { return false }
        let width = image.width
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: rows)) else {
            return false
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows))
            return true
        }
        guard drawn else { return false }

        let total = width * rows
        let limit = max(1, Int((Double(total) * maxNonBlack).rounded(.up)))
        var nonBlack = 0
        var index = 0
        while index + 2 < pixels.count {
            if pixels[index] > channelThreshold
                || pixels[index + 1] > channelThreshold
                || pixels[index + 2] > channelThreshold {
                nonBlack += 1
                if nonBlack > limit {
                    return false
                }
            }
            index += 4
        }
        return true
    }

    /// Fullscreen: covers the display from its top edge, so the notch is in the shot.
    static func includesNotchStrip(_ capture: Capture, displayFrame: DisplayRect) -> Bool {
        let rect = capture.metadata.pointRect
        let startsAtTop = rect.minY <= displayFrame.minY + 1
        let coversWidth = rect.width >= displayFrame.width - 2
        let coversHeight = rect.height >= displayFrame.height * 0.9
        return startsAtTop && coversWidth && coversHeight
    }

    /// True when the bitmap is still the captured rect, not a padded or transformed copy.
    static func pixelSizeMatchesGeometry(_ capture: Capture) -> Bool {
        let scale = capture.metadata.scale.factor
        let expectedWidth = Int((capture.metadata.pointRect.width * scale).rounded())
        let expectedHeight = Int((capture.metadata.pointRect.height * scale).rounded())
        return abs(capture.image.width - expectedWidth) <= 2
            && abs(capture.image.height - expectedHeight) <= 2
    }
}
