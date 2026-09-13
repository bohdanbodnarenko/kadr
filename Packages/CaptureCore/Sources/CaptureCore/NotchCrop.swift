import CoreGraphics
import Foundation
import Shared

/// Crops the MacBook notch strip from a fullscreen still (CleanShot 4.6).
///
/// A notched display's fullscreen screenshot includes the black camera bar. Area
/// captures, windowed shots, and anything that does not cover the top of the
/// display are left alone. The pixel crop only runs when the bitmap still matches
/// the capture's geometry — a window that has already been padded onto a backdrop
/// is a different image, and slicing its top would take padding, not the notch.
public enum NotchCrop {
    /// Crops `capture` when it is a fullscreen still of a notched display.
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

        let crop = CGRect(
            x: 0,
            y: topPixels,
            width: capture.image.width,
            height: capture.image.height - topPixels
        )
        guard let cropped = capture.image.cropping(to: crop) else { return capture }

        let rect = capture.metadata.pointRect
        return Capture(
            image: cropped,
            metadata: CaptureMetadata(
                source: capture.metadata.source,
                displayID: capture.metadata.displayID,
                scale: capture.metadata.scale,
                pointRect: DisplayRect(
                    x: rect.minX,
                    y: rect.minY + topInsetPoints,
                    width: rect.width,
                    height: rect.height - topInsetPoints
                ),
                pixelSize: PixelSize(width: cropped.width, height: cropped.height),
                colorSpaceName: cropped.colorSpace?.name as String? ?? capture.metadata.colorSpaceName,
                frontmostApp: capture.metadata.frontmostApp,
                windowTitle: capture.metadata.windowTitle,
                capturedAt: capture.metadata.capturedAt
            )
        )
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
