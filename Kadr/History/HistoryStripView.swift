import AppKit
import HistoryKit
import Shared

/// Last-8 thumbnail strip in the status-item menu (docs/03 §5, §8.1).
///
/// A custom `NSView` rather than SwiftUI: the menu is built in `menuNeedsUpdate` on
/// the cheapest idle path, and a hosting view would be paid for every open.
final class HistoryStripView: NSView {
    static let thumbnailSize = NSSize(width: 56, height: 40)
    static let spacing: CGFloat = 6
    static let inset: CGFloat = 8

    static func fittingSize(itemCount: Int) -> NSSize {
        let count = CGFloat(max(itemCount, 1))
        let width = Self.inset * 2 + count * Self.thumbnailSize.width + (count - 1) * Self.spacing
        let height = Self.inset * 2 + Self.thumbnailSize.height
        return NSSize(width: width, height: height)
    }

    var onSelect: ((UUID) -> Void)?

    private var buttons: [NSButton] = []

    /// - Parameter thumbnail: what is already in hand for a record, or nil for a
    ///   placeholder. Must not decode: this runs while the menu is opening.
    func update(records: [HistoryRecord], thumbnail: (HistoryRecord) -> NSImage?) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        setFrameSize(Self.fittingSize(itemCount: records.count))

        for (index, record) in records.enumerated() {
            let button = NSButton(frame: thumbFrame(at: index))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.image = thumbnail(record) ?? placeholder
            button.toolTip = record.originalFilename
            button.setAccessibilityLabel(Self.accessibilityLabel(for: record))
            button.target = self
            button.action = #selector(didClick(_:))
            button.identifier = NSUserInterfaceItemIdentifier(record.id.uuidString)
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            button.layer?.masksToBounds = true
            addSubview(button)
            buttons.append(button)
        }
        needsLayout = true
    }

    /// Swaps a placeholder for the real thumbnail once it has been decoded off the main
    /// thread (docs/10 R2.4).
    func setThumbnail(_ image: NSImage, for id: UUID) {
        let identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        buttons.first { $0.identifier == identifier }?.image = image
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = thumbFrame(at: index)
        }
    }

    private func thumbFrame(at index: Int) -> NSRect {
        let x = Self.inset + CGFloat(index) * (Self.thumbnailSize.width + Self.spacing)
        return NSRect(x: x, y: Self.inset, width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
    }

    private var placeholder: NSImage {
        NSImage(systemSymbolName: "photo", accessibilityDescription: "Capture") ?? NSImage()
    }

    static func accessibilityLabel(for record: HistoryRecord) -> String {
        let kind = record.kind.title
        let dimensions = "\(record.width) × \(record.height)"
        let timestamp = record.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(kind), \(record.originalFilename), \(dimensions), \(timestamp)"
    }

    @objc
    private func didClick(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        onSelect?(id)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
