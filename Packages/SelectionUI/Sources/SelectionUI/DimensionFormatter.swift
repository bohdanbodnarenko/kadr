import CoreGraphics
import Shared

/// The "W × H" readout that follows the selection (docs/03 §1.1).
///
/// The badge shows points *and* pixels because they differ on Retina and the pixel
/// figure is the one that has to match the exported file — the doc's acceptance
/// criterion is precisely that the badge matches the output size.
public enum DimensionFormatter {
    /// e.g. `"640 × 480"`, or `"640 × 480 pt · 1280 × 960 px"` on a Retina display.
    public static func text(for rect: CGRect, scale: DisplayScale) -> String {
        let points = size(of: rect)
        guard scale.factor != 1 else {
            return "\(points.width) × \(points.height)"
        }
        let pixels = pixelSize(of: rect, scale: scale)
        return "\(points.width) × \(points.height) pt · \(pixels.width) × \(pixels.height) px"
    }

    /// The point size a user would read off the badge.
    public static func size(of rect: CGRect) -> PixelSize {
        PixelSize(width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
    }

    /// The pixel size the exported file will have.
    ///
    /// Derived from the rect's edges rather than its width, so it agrees with
    /// `DisplayGeometry.pixels(for:)` — the badge promising 800 px and the file being
    /// 799 px is exactly the bug this avoids.
    public static func pixelSize(of rect: CGRect, scale: DisplayScale) -> PixelSize {
        let minX = (rect.minX * scale.factor).rounded()
        let minY = (rect.minY * scale.factor).rounded()
        let maxX = (rect.maxX * scale.factor).rounded()
        let maxY = (rect.maxY * scale.factor).rounded()
        return PixelSize(width: Int(maxX - minX), height: Int(maxY - minY))
    }

    /// The loupe's readout: pointer position in points, and the colour under it.
    public static func pointerText(at point: CGPoint) -> String {
        "\(Int(point.x.rounded())), \(Int(point.y.rounded()))"
    }

    /// Hex for the colour under the pointer, as the eyedropper-style readout.
    public static func hexText(red: UInt8, green: UInt8, blue: UInt8) -> String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}
