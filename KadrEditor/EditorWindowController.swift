import AnnotationModel
import AnnotationRender
import AppKit
import EditorUI
import ImageIO
import MediaExport
import os
import Shared
import SwiftUI
import UniformTypeIdentifiers

/// One editor window over one capture (docs/03 §3).
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    enum OpenError: LocalizedError {
        case unreadableImage(URL)

        var errorDescription: String? {
            switch self {
            case let .unreadableImage(url):
                "“\(url.lastPathComponent)” is not an image Kadr can read."
            }
        }
    }

    private let fileURL: URL
    private let baseImage: CGImage
    private let model: EditorDocumentModel
    private let renderer = AnnotationExportRenderer()
    private let logger = KadrLog.logger(.app)

    private var window: NSWindow?
    private var hostingView: NSView?

    var onClose: (() -> Void)?

    init(fileURL: URL) throws {
        self.fileURL = fileURL

        // `.kadr` carries its own annotations; anything else is a fresh capture.
        if fileURL.pathExtension.lowercased() == KadrDocumentFile.fileExtension {
            let contents = try KadrDocumentFile.read(from: fileURL)
            guard let image = Self.decodeImage(from: contents.baseImagePNG) else {
                throw OpenError.unreadableImage(fileURL)
            }
            baseImage = image
            model = EditorDocumentModel(document: contents.document)
        } else {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw OpenError.unreadableImage(fileURL)
            }
            baseImage = image

            // Captures are written with a DPI tag that records their scale, so the editor
            // shows a Retina screenshot at the size the user selected rather than double.
            let scale = Self.scale(of: source)
            let size = CGSize(
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
            model = EditorDocumentModel(document: AnnotationDocument(
                baseImage: BaseImageReference(size: size, scale: scale)
            ))
        }
        super.init()
    }

    func show() {
        let root = EditorRootView(model: model, baseImage: baseImage) { [weak self] action in
            self?.export(action)
        }
        let hosting = NSHostingView(rootView: root)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1100, height: 720)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        // The title-bar proxy icon: dragging it hands the file to another app (docs/03 §3).
        window.representedURL = fileURL
        window.contentView = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("app.kadr.Kadr.Editor.window")

        self.window = window
        hostingView = hosting
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window?.contentView = nil
        window = nil
        hostingView = nil
        onClose?()
    }

    // MARK: - Export

    private func export(_ action: EditorRootView.ExportAction) {
        do {
            let image = try renderer.render(
                baseImage: baseImage,
                document: model.document,
                includeAnnotations: action != .copyWithoutAnnotations
            )
            switch action {
            case .copy, .copyWithoutAnnotations:
                copyToClipboard(image)
            case .save:
                try save(image)
            }
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copyToClipboard(_ image: CGImage) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data as Data, forType: .png)
        logger.info("Copied the flattened capture")
    }

    private func save(_ image: CGImage) throws {
        let writer = CaptureFileWriter()
        let directory = fileURL.deletingLastPathComponent()
        let name = fileURL.deletingPathExtension().lastPathComponent

        let url = try writer.write(
            image,
            to: directory,
            template: FilenameTemplate("\(name) annotated"),
            options: EncodingOptions(scale: DisplayScale(model.document.baseImage.scale))
        )
        logger.info("Saved \(url.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Reading

    private static func decodeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Recovers the capture's scale from its DPI tag, defaulting to 1 for images that
    /// carry none.
    private static func scale(of source: CGImageSource) -> CGFloat {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0
        else { return 1 }
        return max(1, CGFloat((dpi / 72).rounded()))
    }
}
