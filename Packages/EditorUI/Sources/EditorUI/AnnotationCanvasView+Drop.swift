import AnnotationModel
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Dropping another capture onto the canvas (docs/03 §3 P2, docs/06 M24).
///
/// A drop, not an "Insert image…" dialog, because the images being combined are almost
/// always ones the user has just taken — sitting in the Quick Access Overlay, in History,
/// or on the Desktop — and dragging one of those onto the canvas is a single gesture.
public extension AnnotationCanvasView {
    /// The types worth accepting: a file the Finder or History dragged, or raw image data
    /// from an app that promises no file.
    internal static var acceptedDropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let drop = Self.image(from: sender.draggingPasteboard) else { return false }
        let point = imagePoint(fromWindowPoint: sender.draggingLocation)
        guard model.insertImage(pngData: drop.png, pixelSize: drop.pixelSize, at: point) != nil else {
            return false
        }
        // The image is a new annotation like any other, so the ordinary refresh path is
        // what puts it on screen — and what makes it undoable.
        documentChangedExternally()
        onDocumentChanged?()
        return true
    }

    private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            || sender.draggingPasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// Normalises whatever was dropped into PNG data plus its pixel size.
    ///
    /// PNG whatever came in: the document carries the bytes, and one format inside it
    /// means one decode path and no surprises when a `.kadr` is reopened elsewhere.
    internal static func image(from pasteboard: NSPasteboard) -> (png: Data, pixelSize: CGSize)? {
        if let image = imageFromFile(on: pasteboard) {
            return encode(image)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                continue
            }
            return encode(image)
        }
        return nil
    }

    /// The first readable image among the dropped files.
    private static func imageFromFile(on pasteboard: NSPasteboard) -> CGImage? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encode(_ image: CGImage) -> (png: Data, pixelSize: CGSize)? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, CGSize(width: image.width, height: image.height))
    }
}
