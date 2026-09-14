import CoreGraphics
import Shared

public extension FrozenDisplay {
    /// Crops the selection straight out of the frozen bitmap.
    ///
    /// This is what makes area capture WYSIWYG (docs/03 §1.1). Re-capturing the region
    /// after the user releases the mouse would photograph whatever the screen shows
    /// *then* — a video that has advanced, a menu that has closed, a notification that
    /// arrived — instead of the frozen frame they actually selected on.
    ///
    /// - Parameter localRect: the selection in display-local points.
    func croppedImage(localRect: CGRect) -> CGImage? {
        guard !localRect.isEmpty else { return nil }
        let pixels = geometry.pixels(for: DisplayRect(cgRect: localRect))
        guard !pixels.isEmpty else { return nil }

        let clamped = pixels.cgRect.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !clamped.isEmpty else { return nil }
        return image.cropping(to: clamped)
    }
}
