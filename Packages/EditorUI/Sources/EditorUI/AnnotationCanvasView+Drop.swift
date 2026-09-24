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
    /// The types worth accepting: a file the Finder or History dragged, raw image data
    /// from an app that promises no file, and a file *promise* — which is what Kadr's own
    /// Quick Access cards drag (T-ED-5).
    internal static var acceptedDropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let point = imagePoint(fromWindowPoint: sender.draggingLocation)
        if let drop = Self.image(from: sender.draggingPasteboard) {
            return insertDropped(drop, at: point)
        }
        return receivePromisedImage(from: sender.draggingPasteboard, at: point)
    }

    private func insertDropped(_ drop: (png: Data, pixelSize: CGSize), at point: CGPoint) -> Bool {
        guard model.insertImage(pngData: drop.png, pixelSize: drop.pixelSize, at: point) != nil else {
            return false
        }
        // The image is a new annotation like any other, so the ordinary refresh path is
        // what puts it on screen — and what makes it undoable.
        documentChangedExternally()
        onDocumentChanged?()
        return true
    }

    /// Asks the source to write its promised file into a private folder, then inserts it.
    ///
    /// The file is read and deleted straight away: it is Kadr's copy of someone else's
    /// capture, and the document keeps the bytes.
    private func receivePromisedImage(from pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        guard let receiver = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver])?.first
        else {
            return false
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr-drops-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        receiver.receivePromisedFiles(atDestination: directory, operationQueue: .main) { [weak self] url, error in
            defer { try? FileManager.default.removeItem(at: directory) }
            guard error == nil, let drop = Self.image(at: url) else { return }
            MainActor.assumeIsolated {
                _ = self?.insertDropped(drop, at: point)
            }
        }
        return true
    }

    private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
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

    /// A promised file, once it has been written.
    internal static func image(at url: URL) -> (png: Data, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return encode(image)
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
