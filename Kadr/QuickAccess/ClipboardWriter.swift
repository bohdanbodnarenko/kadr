import AppKit
import Foundation
import MediaExport
import Shared
import UniformTypeIdentifiers

/// Multi-flavour clipboard writes (docs/16 X-1).
///
/// Native bytes go on the item immediately. PNG and TIFF are registered through a data
/// provider so a 5K HEIC is not decoded unless a receiver asks. `.fileURL` is only
/// attached for a file that will still be there after staging moves.
///
/// `nonisolated` because AppKit's data-provider callback is not main-actor isolated, and
/// the target defaults to `@MainActor` (Swift 6). `@unchecked Sendable` is the singleton
/// plus a lock around the one mutable payload.
final nonisolated class ClipboardWriter: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    static let shared = ClipboardWriter()

    private struct Payload {
        var data: Data
        var changeCount: Int
    }

    private let lock = NSLock()
    private var payload: Payload?

    func write(
        data: Data,
        format: ImageFormat,
        fileURL: URL?,
        pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: nativeType(format))
        let flavors = PasteboardFlavorPlan.flavors(for: format, isFinalized: fileURL != nil)
        var lazyTypes: [NSPasteboard.PasteboardType] = []
        if flavors.contains(.pngFallback) {
            lazyTypes.append(.png)
        }
        if flavors.contains(.tiffFallback) {
            lazyTypes.append(.tiff)
        }
        if !lazyTypes.isEmpty {
            item.setDataProvider(self, forTypes: lazyTypes)
        }
        if flavors.contains(.fileURL), let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
        lock.withLock { payload = Payload(data: data, changeCount: pasteboard.changeCount) }
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let pasteboard else { return }
        let snapshot = lock.withLock { payload }
        guard let snapshot, snapshot.changeCount == pasteboard.changeCount else { return }
        pasteboard.setData(fallback(from: snapshot.data, as: type), forType: type)
    }

    private func nativeType(_ format: ImageFormat) -> NSPasteboard.PasteboardType {
        switch format {
        case .png: .png
        case .jpeg, .heic, .webp: NSPasteboard.PasteboardType(format.contentType.identifier)
        }
    }

    private func fallback(from data: Data, as type: NSPasteboard.PasteboardType) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else { return data }
        if type == .tiff {
            return tiff
        }
        guard let bitmap = NSBitmapImageRep(data: tiff) else { return data }
        return bitmap.representation(using: .png, properties: [:]) ?? data
    }
}
