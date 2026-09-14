import AppKit
import UniformTypeIdentifiers

/// Accepts a file dropped on the menu-bar icon and opens it in the editor (docs/03 §8.1).
///
/// Clicks still go to the status button: mouse events are forwarded, and only the
/// dragging-destination methods are handled here.
final class StatusItemDropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        superview?.rightMouseUp(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.droppedFile(from: sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = Self.droppedFile(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    /// Images and `.kadr` projects; recordings go through the overlay, not this drop.
    static func accepts(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "kadr" {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func droppedFile(from sender: any NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first(where: accepts)
    }
}
