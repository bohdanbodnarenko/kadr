import CoreGraphics

extension CGContext {
    /// Draws `image` into `rect` of a context already flipped to the model's top-left origin.
    ///
    /// `CGContext.draw(_:in:)` puts the image's top edge at the rect's `maxY`, which is the
    /// *bottom* of a y-down canvas — so a plain call there mirrors the picture vertically.
    /// The flip is undone around this one draw rather than the image being mirrored, which
    /// is what every command that draws a bitmap in the export's space has to do, and why it
    /// lives in one place: forgetting it is silent until somebody opens the file.
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.midY * 2)
        scaleBy(x: 1, y: -1)
        draw(image, in: rect)
        restoreGState()
    }
}
