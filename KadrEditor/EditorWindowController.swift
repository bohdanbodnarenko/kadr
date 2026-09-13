import AnnotationModel
import AnnotationRender
import AppKit
import EditorUI
import ImageIO
import os
import Shared
import SwiftUI
import UniformTypeIdentifiers

/// One editor window over one capture (docs/03 §3).
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, RedactionAssisting, SubjectLifting {
    enum OpenError: LocalizedError {
        case unreadableImage(URL)

        var errorDescription: String? {
            switch self {
            case let .unreadableImage(url):
                "“\(url.lastPathComponent)” is not an image Kadr can read."
            }
        }
    }

    let fileURL: URL
    let baseImage: CGImage
    /// The immutable capture, encoded once at open so autosave does not re-PNG a 5K
    /// image every 1.5 s (docs/10 R2.6).
    let cachedBasePNG: Data
    let model: EditorDocumentModel
    let renderer = AnnotationExportRenderer()
    let logger = KadrLog.logger(.app)
    let vision = VisionClient()

    var window: NSWindow?
    private var hostingView: NSView?

    /// Keeps a recoverable copy while the user works (docs/07 M7).
    let autosave = EditorAutosave()
    private var autosaveTask: Task<Void, Never>?
    /// True once the user has been asked about closing, so the second close goes through.
    private var isClosingConfirmed = false
    /// How long the document has to be still before a copy is written.
    private static let autosaveSettleMilliseconds = 1500

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
            cachedBasePNG = contents.baseImagePNG
            model = EditorDocumentModel(document: contents.document)
        } else {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw OpenError.unreadableImage(fileURL)
            }
            baseImage = image
            cachedBasePNG = try Self.pngData(of: image)

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
        model.isCanvasLocked = EditorCanvasPreferences.lockCanvasByDefault()
        super.init()
    }

    func show() {
        let root = EditorRootView(
            model: model,
            baseImage: baseImage,
            redactionAssist: self,
            subjectLift: self
        ) { [weak self] action in
            self?.export(action)
        }
        let hosting = NSHostingView(rootView: root)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: EditorWindowGeometry.minSize),
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
        let autosaveName = "app.kadr.Kadr.Editor.window"
        if !window.setFrameUsingName(autosaveName) {
            let screen = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? CGRect(origin: .zero, size: CGSize(width: 1440, height: 900))
            window.setFrame(
                EditorWindowGeometry.preferredFrame(
                    canvasSize: model.document.orientedCanvasSize,
                    on: screen
                ),
                display: false
            )
        }
        window.setFrameAutosaveName(autosaveName)

        self.window = window
        hostingView = hosting
        window.makeKeyAndOrderFront(nil)

        offerRecoveryIfAny()
        trackChangesForAutosave()
    }

    // MARK: - Unsaved work (docs/07 M7)

    /// Closing used to discard the annotations silently, with no prompt and no copy.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingConfirmed, model.hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Save your changes to “\(fileURL.lastPathComponent)”?"
        alert.informativeText = "Kadr will write a project file beside the capture so the "
            + "annotations stay editable. Otherwise they are lost."
        alert.addButton(withTitle: "Save Project")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProject()
            // A failed save leaves the work unsaved, and closing anyway would throw it
            // away — exactly what the prompt exists to prevent.
            guard !model.hasUnsavedChanges else { return false }
            isClosingConfirmed = true
            return true
        case .alertSecondButtonReturn:
            autosave.discard(for: fileURL)
            isClosingConfirmed = true
            return true
        default:
            return false
        }
    }

    /// Offers work a previous session left behind — a crash, a force quit, a power cut.
    private func offerRecoveryIfAny() {
        guard let recovered = autosave.read(for: fileURL) else { return }
        guard recovered.document.commands != model.document.commands else {
            autosave.discard(for: fileURL)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Kadr has unsaved changes to “\(fileURL.lastPathComponent)”."
        alert.informativeText = "The editor closed before these annotations were saved."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            model.replaceDocument(recovered.document)
            logger.info("Restored autosaved annotations")
        } else {
            autosave.discard(for: fileURL)
        }
    }

    /// Re-arms itself after every change, which is how Observation reports more than once.
    private func trackChangesForAutosave() {
        withObservationTracking {
            _ = model.document.commands
        } onChange: { [weak self] in
            // Weak in the outer closure as well as the inner one: capturing strongly here
            // and weakly there means the observation holds the window controller alive
            // until the next change, which for a window nobody touches again is forever.
            Task { @MainActor in
                guard let self else { return }
                self.scheduleAutosave()
                self.trackChangesForAutosave()
            }
        }
    }

    /// Writes a copy once the document has been still for a moment.
    ///
    /// Debounced rather than written per edit: a drag is dozens of committed changes, and
    /// re-encoding the base image PNG for each of them would make the editor stutter.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard model.hasUnsavedChanges else {
            autosave.discard(for: fileURL)
            return
        }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.autosaveSettleMilliseconds))
            guard !Task.isCancelled else { return }
            self?.writeAutosave()
        }
    }

    private func writeAutosave() {
        let contents = KadrDocumentFile.Contents(document: model.document, baseImagePNG: cachedBasePNG)
        let snapshotURL = fileURL
        let snapshotAutosave = autosave
        let snapshotLogger = logger
        Task.detached {
            do {
                try snapshotAutosave.write(contents, for: snapshotURL)
            } catch {
                snapshotLogger.error("Could not autosave: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        autosaveTask?.cancel()
        autosaveTask = nil
        window?.delegate = nil
        window?.contentView = nil
        window = nil
        hostingView = nil
        onClose?()
    }

    // MARK: - Export

    func export(_ action: EditorRootView.ExportAction) {
        switch action {
        case .saveProject:
            saveProject()
        case .insertImage:
            insertImageFromOpenPanel()
        case .insertFromClipboard:
            insertImageFromClipboard()
        case .copy, .copyFlattened, .copyWithoutAnnotations, .save, .saveAs, .print, .pin, .share:
            exportRendered(action)
        }
    }

    func exportRendered(_ action: EditorRootView.ExportAction) {
        do {
            let image = try renderer.render(
                baseImage: baseImage,
                document: model.document,
                includeAnnotations: action != .copyWithoutAnnotations,
                exportScale: model.exportScale
            )
            switch action {
            case .copy, .copyFlattened, .copyWithoutAnnotations:
                copyToClipboard(image)
            case .save:
                try save(image)
            case .saveAs:
                saveAs(image)
            case .print:
                printImage(image)
            case .pin:
                pinImage(image)
            case .share:
                shareImage(image)
            case .saveProject, .insertImage, .insertFromClipboard:
                break
            }
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
