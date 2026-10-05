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
        let destination = documentURL
            .deletingPathExtension()
            .appendingPathExtension(KadrDocumentFile.fileExtension)
        do {
            try writeProject(to: destination, addToHistory: true)
            rebind(to: destination)
            noteProjectKeepsOriginalPixels()
            logger.info("Saved project \(destination.lastPathComponent, privacy: .public)")
        } catch {
            model.failExport(.save, message: error.localizedDescription)
            logger.error("Could not save the project: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the project. Never brings Finder forward: a save is the silent write
    /// (docs/03:171); only Show in Finder reveals (T-ED-1).
    func writeProject(to destination: URL, addToHistory: Bool = true) throws {
        try KadrDocumentFile.write(projectContents(), to: destination)
        markClean()
        if addToHistory {
            addToLibrary(destination)
        }
    }

    /// The project as it would be written now, Export Size included (docs/18 ED-12).
    func projectContents() throws -> KadrDocumentFile.Contents {
        var contents = try basePNG.contents(for: model.document)
        contents.exportScale = Double(model.exportScale)
        return contents
    }

    /// The document matches what is on disk.
    func markClean() {
        model.markSaved()
        autosave.discard(for: documentURL)
        window?.isDocumentEdited = false
    }

    /// Points the window, its title and its proxy icon at `url`, so the next ⌘S, the
    /// title bar and a drag of the proxy icon all mean the file just written (T-ED-1).
    ///
    /// The proxy icon is the flattened image, never the `.kadr`: the project holds the
    /// untouched base pixels, so dragging it into Mail would send what the user blurred
    /// (docs/18 ED-3). With no flattened image on disk there is no proxy at all.
    func rebind(to url: URL) {
        guard url != documentURL else { return }
        autosave.discard(for: documentURL)
        documentURL = url
        window?.title = url.lastPathComponent
        window?.representedURL = proxyURL
    }

    /// What the title-bar proxy hands out: the image the user sees, redactions burned in.
    var proxyURL: URL? {
        Self.proxyURL(for: documentURL, existingImage: capturedImageURL)
    }

    /// `document` itself when it is an image; otherwise the image beside the project, if
    /// one exists. Never a `.kadr` (docs/18 ED-3).
    static func proxyURL(for document: URL, existingImage: URL?) -> URL? {
        guard document.pathExtension.lowercased() == KadrDocumentFile.fileExtension else { return document }
        return existingImage
    }

    /// Says once, the first time a project with redactions is written, that the project
    /// keeps the original pixels and the flattened image is the one to share (docs/18 ED-3).
    func noteProjectKeepsOriginalPixels() {
        guard Self.containsRedactions(model.document.commands),
              !UserDefaults.standard.bool(forKey: Self.projectPixelsNoticeKey),
              let window
        else { return }
        UserDefaults.standard.set(true, forKey: Self.projectPixelsNoticeKey)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "The project keeps the original pixels."
        alert.informativeText = "Redactions are burned into the saved image, which is the file to share. "
            + "The .kadr project keeps the unredacted capture so you can edit the redactions later; "
            + "don't send the project to anyone who shouldn't see what's under them."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    static let projectPixelsNoticeKey = "editorProjectPixelsNoticeShown"

    static func containsRedactions(_ commands: [AnnotationCommand]) -> Bool {
        commands.contains {
            if case .redaction = $0 {
                true
            } else {
                false
            }
        }
    }

    func addToLibrary(_ url: URL) {
        var components = URLComponents()
        components.scheme = "kadr"
        components.host = "add-to-history"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let target = components.url else { return }
        Self.openInBackground(target)
    }

    /// Hands a `kadr://` request to the agent without bringing anything forward.
    static func openInBackground(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    /// Writes the flattened image, plus the selected annotations as a second type when there
    /// are any, so other apps always get pixels and Kadr's own paste gets objects (ED-2).
    @discardableResult
    func copyToClipboard(_ image: CGImage, annotations: Data? = nil) -> Bool {
        guard let data = try? ImageEncoder().encode(image, options: exportEncodingOptions) else {
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        if let annotations {
            NSPasteboard.general.setData(annotations, forType: .kadrAnnotations)
        }
        logger.info("Copied the flattened capture")
        return true
    }

    /// Whether this window edits a file the editor copied in from outside, which lives in
    /// Kadr's hidden imports folder. ⌘S there goes to Save As, so the result lands
    /// somewhere the user can find it (T-ED-9).
    var editsImportedCopy: Bool {
        documentURL.standardizedFileURL.deletingLastPathComponent().path
            == CaptureImporter.importsDirectory.standardizedFileURL.path
    }

    /// Where ⌘S writes now.
    var saveTargets: EditorSaveTargets {
        chosenSaveTargets ?? EditorSaveTargets.plan(
            document: documentURL,
            keepOriginal: Self.agentKeepsOriginalWhenAnnotating,
            writesProject: EditorCanvasPreferences.writesSidecarOnSave()
        )
    }

    /// ⌘S: the flattened image and its project, the same pair every time (T-ED-1).
    func save(_ image: CGImage) throws {
        let targets = saveTargets
        let original = capturedImageURL ?? targets.flattened
        let previousHash = Self.fileHash(at: targets.flattened)

        try write(image, to: targets.flattened)
        if let project = targets.project {
            try writeProject(to: project, addToHistory: false)
        }
        markClean()
        rebind(to: targets.document)
        if targets.project != nil {
            noteProjectKeepsOriginalPixels()
        }
        logger.info("Saved \(targets.flattened.lastPathComponent, privacy: .public)")
        CaptureSavedNotice.post(.init(original: original, saved: targets.flattened, previousHash: previousHash))
    }

    /// Encodes in the format the destination's extension names.
    func write(_ image: CGImage, to url: URL, quality: Double? = nil) throws {
        var options = exportEncodingOptions
        options.format = ImageFormat(fileExtension: url.pathExtension) ?? .png
        if let quality {
            options.quality = quality
        }
        try CaptureFileWriter().write(image, to: url, options: options)
    }

    /// The capture image the card and History know this document by: the file itself, or
    /// the image beside a project.
    var capturedImageURL: URL? {
        guard documentURL.pathExtension.lowercased() == KadrDocumentFile.fileExtension else {
            return documentURL
        }
        let base = documentURL.deletingPathExtension()
        return EditorSaveTargets.imageExtensions
            .flatMap { [$0, $0.uppercased()] }
            .map { base.appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func fileHash(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Flattened image (or a `.kadr`) to a path the user picks (CleanShot §8.5).
    func presentSaveAsSheet(for image: CGImage, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let window else {
            model.endExport()
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = documentURL.deletingPathExtension().lastPathComponent
        panel.directoryURL = editsImportedCopy
            ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            : documentURL.deletingLastPathComponent()
        panel.message = "Save this capture"
        let current = ImageFormat(fileExtension: (capturedImageURL ?? documentURL).pathExtension) ?? .png
        let accessory = SaveAsAccessory(panel: panel, initial: .image(current))
        panel.accessoryView = accessory.view
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.model.endExport() }
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            do {
                try saveAs(image, to: url, quality: accessory.quality)
                logger.info("Saved \(url.lastPathComponent, privacy: .public)")
                completion?(true)
            } catch {
                completion?(false)
                model.failExport(.saveAs, message: error.localizedDescription)
                logger.error("Save As failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes to a destination the user picked and rebinds the window to it, so the title,
    /// the proxy icon and the next ⌘S all follow (T-ED-1).
    func saveAs(_ image: CGImage, to url: URL, quality: Double? = nil) throws {
        guard let targets = EditorSaveTargets.chosen(
            url,
            writesProject: EditorCanvasPreferences.writesSidecarOnSave()
        ) else {
            try writeProject(to: url)
            chosenSaveTargets = nil
            rebind(to: url)
            noteProjectKeepsOriginalPixels()
            return
        }
        try write(image, to: targets.flattened, quality: quality)
        if let project = targets.project {
            try writeProject(to: project, addToHistory: false)
        }
        markClean()
        chosenSaveTargets = targets
        rebind(to: targets.document)
        if targets.project != nil {
            noteProjectKeepsOriginalPixels()
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
            Self.openInBackground(target)
        } catch {
            model.failExport(.pin, message: error.localizedDescription)
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
            model.failExport(.share, message: error.localizedDescription)
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
        _ = model.insertImage(pngData: png, pixelSize: pixelSize, at: model.nextPastePoint())
    }

    /// A PNG for Pin or Share, in the editor's temporary folder.
    ///
    /// Not beside the capture: those used to leave "<stem> pin.png" and "<stem> share.png"
    /// in the user's folder after every pin or share (T-ED-12). The same name is reused, so
    /// repeating the action replaces the file rather than adding one, and the system clears
    /// the temporary folder.
    func writeExportPNG(_ image: CGImage, suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr Editor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = documentURL.deletingPathExtension().lastPathComponent
        let url = directory.appendingPathComponent("\(stem) \(suffix).png")
        let data = try ImageEncoder().encode(image, options: exportEncodingOptions)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Matches the agent's General-pane sRGB toggle by reading the agent defaults
    /// domain — the two processes do not share `UserDefaults.standard`.
    var exportEncodingOptions: EncodingOptions {
        // The DPI tag follows the pixels: a 2× capture exported at half size is a 1× image,
        // and tagging it 144 DPI made it open at half its size elsewhere (docs/18 ED-12).
        EncodingOptions(
            format: .png,
            scale: DisplayScale(max(model.document.baseImage.scale * model.exportScale, 0.01)),
            convertToSRGB: Self.agentConvertsExportsToSRGB
        )
    }

    /// The agent owns this setting; `EditorCanvasPreferences` reads its domain (T-ED-3).
    static var agentConvertsExportsToSRGB: Bool {
        EditorCanvasPreferences.convertsExportsToSRGB()
    }

    static var agentKeepsOriginalWhenAnnotating: Bool {
        EditorCanvasPreferences.keepOriginalWhenAnnotating()
    }
}
