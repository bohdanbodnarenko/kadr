import AppKit
import Foundation

/// Renders an emoji into PNG bytes the composition tool can place (docs/03 §3 P2).
enum EmojiSticker {
    /// A short, always-available strip — the character palette is still ⌃⌘Space.
    static let catalog: [String] = [
        "😀", "😂", "😍", "🤔", "😎", "🥳",
        "👍", "👎", "👏", "🙌", "✅", "❌",
        "🔥", "⭐️", "💡", "⚠️", "❤️", "🎉",
        "👀", "💯", "🚀", "📌", "📝", "🔗"
    ]

    /// Point size of the glyph before it is scaled to the document.
    static let pointSize: CGFloat = 96

    static func png(emoji: String, scale: CGFloat) -> (data: Data, pixelSize: CGSize)? {
        let font = NSFont(name: "Apple Color Emoji", size: pointSize) ?? .systemFont(ofSize: pointSize)
        let drawn = NSAttributedString(string: emoji, attributes: [.font: font])
        let size = drawn.size()
        guard size.width > 0, size.height > 0 else { return nil }

        let factor = max(1, scale)
        let pixels = CGSize(
            width: ceil(size.width * factor),
            height: ceil(size.height * factor)
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width),
            pixelsHigh: Int(pixels.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: factor, y: factor)
        drawn.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, pixels)
    }
}
