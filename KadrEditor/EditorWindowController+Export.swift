import AnnotationModel
import AppKit
import CoreGraphics
import CryptoKit
import EditorUI
import MediaExport
import os
import Shared
import UniformTypeIdentifiers

extension EditorWindowController {
    /// Writes a re-editable `.kadr` beside the capture, and tells the agent about it.
    ///
    /// The agent owns the library, so the project is added to History through the URL
    /// scheme rather than by this process reaching into the store (docs/03 §8.4,
    /// docs/06 M24). If the agent is not running the file is still written — the save is
    /// the promise, the library entry is the convenience.
    func saveProject() {
        let destination = fileURL
            .deletingPathExtension()
            .appendingPathExtension(KadrDocumentFile.fileExtension)
        do {
            try writeProject(to: destination, reveal: true, addToHistory: true)
            logger.info("Saved project \(destination.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Could not save the project: \(error.localizedDescription, privacy: .public)")
        }
    }

    func writeProject(to destination: URL, reveal: Bool = true, addToHistory: Bool = true) throws {
        try KadrDocumentFile.write(
            KadrDocumentFile.Contents(document: model.document, baseImagePNG: cachedBasePNG),
            to: destination
        )
        model.markSaved()
        autosave.discard(for: fileURL)
        window?.isDocumentEdited = false
        if addToHistory {
            addToLibrary(destination)
        }
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func addToLibrary(_ url: URL) {
        var components = URLComponents()
        components.scheme = "kadr"
        components.host = "add-to-history"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let target = components.url else { return }
        NSWorkspace.shared.open(target)
    }

    @discardableResult
    func copyToClipboard(_ image: CGImage) -> Bool {
        guard let data = try? ImageEncoder().encode(image, options: exportEncodingOptions) else {
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        logger.info("Copied the flattened capture")
        return true
    }

    func save(_ image: CGImage) throws {
        let previousHash = Self.fileHash(at: fileURL)
        let writer = CaptureFileWriter()
        let directory = fileURL.deletingLastPathComponent()
        let stem = EditorCanvasPreferences.flattenedSaveStem(
            for: fileURL,
            keepOriginal: Self.agentKeepsOriginalWhenAnnotating
        )

        let url: URL
        if Self.agentKeepsOriginalWhenAnnotating {
            url = try writer.write(
                image,
                to: directory,
                template: FilenameTemplate(stem),
                options: exportEncodingOptions
            )
        } else {
            var options = exportEncodingOptions
            options.format = ImageFormat(fileExtension: fileURL.pathExtension) ?? .png
            url = fileURL
            try writer.write(image, to: url, options: options)
        }
        if EditorCanvasPreferences.writesSidecarOnSave() {
            let sidecar = url.deletingPathExtension().appendingPathExtension(KadrDocumentFile.fileExtension)
            try writeProject(to: sidecar, reveal: false, addToHistory: false)
        }
        logger.info("Saved \(url.lastPathComponent, privacy: .public)")
        model.markSaved()
        autosave.discard(for: fileURL)
        window?.isDocumentEdited = false
        CaptureSavedNotice.post(.init(original: fileURL, saved: url, previousHash: previousHash))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func fileHash(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Flattened image (or a `.kadr`) to a path the user picks (CleanShot §8.5).
    func presentSaveAsSheet(for image: CGImage) {
        guard let window else {
            model.endExport()
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.message = "Save this capture"
        var types = ImageFormat.writable.map(\.contentType)
        if let project = UTType(filenameExtension: KadrDocumentFile.fileExtension) {
            types.append(project)
        }
        panel.allowedContentTypes = types
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.model.endExport() }
            guard response == .OK, let url = panel.url else { return }
            do {
                if url.pathExtension.lowercased() == KadrDocumentFile.fileExtension {
                    try writeProject(to: url)
                } else {
                    var options = exportEncodingOptions
                    options.format = ImageFormat(fileExtension: url.pathExtension) ?? .png
                    try CaptureFileWriter().write(image, to: url, options: options)
                    model.markSaved()
                    autosave.discard(for: fileURL)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                logger.info("Saved \(url.lastPathComponent, privacy: .public)")
            } catch {
                model.failExport(.saveAs, message: error.localizedDescription)
                logger.error("Save As failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func printImage(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false
        printInfo.verticalPagination = .automatic
        let view = PaginatedImagePrintView(image: nsImage, printInfo: printInfo)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    func pinImage(_ image: CGImage) {
        do {
            let url = try writeExportPNG(image, suffix: "pin")
            var components = URLComponents()
            components.scheme = "kadr"
            components.host = "pin"
            components.queryItems = [URLQueryItem(name: "path", value: url.path)]
            guard let target = components.url else { return }
            NSWorkspace.shared.open(target)
        } catch {
            logger.error("Pin from editor failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func shareImage(_ image: CGImage) {
        guard let view = window?.contentView else { return }
        do {
            let url = try writeExportPNG(image, suffix: "share")
            let picker = NSSharingServicePicker(items: [url])
            let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 12, width: 1, height: 1)
            picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        } catch {
            logger.error("Share from editor failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func insertImageFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertImportedImage(from: url)
    }

    func insertImageFromClipboard() {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let imported = EditorImageImporter.png(from: cgImage)
        else {
            insertImageFromOpenPanel()
            return
        }
        placeImportedImage(imported.data, pixelSize: imported.pixelSize)
    }

    func insertImportedImage(from url: URL) {
        guard let imported = EditorImageImporter.png(from: url) else {
            logger.error("Could not read \(url.lastPathComponent, privacy: .public)")
            return
        }
        placeImportedImage(imported.data, pixelSize: imported.pixelSize)
    }

    func placeImportedImage(_ png: Data, pixelSize: CGSize) {
        let point = CGPoint(
            x: model.document.contentRect.midX,
            y: model.document.contentRect.midY
        )
        _ = model.insertImage(pngData: png, pixelSize: pixelSize, at: point)
    }

    func writeExportPNG(_ image: CGImage, suffix: String) throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let url = directory.appendingPathComponent("\(stem) \(suffix).png")
        let data = try ImageEncoder().encode(image, options: exportEncodingOptions)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Matches the agent's General-pane sRGB toggle by reading the agent defaults
    /// domain — the two processes do not share `UserDefaults.standard`.
    var exportEncodingOptions: EncodingOptions {
        EncodingOptions(
            format: .png,
            scale: DisplayScale(model.document.baseImage.scale),
            convertToSRGB: Self.agentConvertsExportsToSRGB
        )
    }

    /// `CFPreferences` rather than a suite name: `UserDefaults(suiteName:)` would
    /// create a new suite, not read the agent's standard domain.
    static var agentConvertsExportsToSRGB: Bool {
        let raw = CFPreferencesCopyAppValue(
            "general.convertExportsToSRGB" as CFString,
            "app.kadr.Kadr" as CFString
        )
        if let flag = raw as? Bool {
            return flag
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return false
    }

    static var agentKeepsOriginalWhenAnnotating: Bool {
        let raw = CFPreferencesCopyAppValue(
            EditorCanvasPreferences.keepOriginalWhenAnnotatingKey as CFString,
            "app.kadr.Kadr" as CFString
        )
        if let flag = raw as? Bool {
            return flag
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return true
    }
}
