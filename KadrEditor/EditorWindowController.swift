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
final class EditorWindowController: NSResponder, NSWindowDelegate, NSMenuItemValidation, RedactionAssisting,
    SubjectLifting
{
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
    let canvasSession = EditorCanvasSession()
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        let root = EditorRootView(
            model: model,
            baseImage: baseImage,
            canvasSession: canvasSession,
            redactionAssist: self,
            subjectLift: self,
            onExport: { [weak self] action in
                self?.export(action)
            },
            onRetryExport: { [weak self] action in
                self?.retryExport(action)
            },
            onChooseExportLocation: { [weak self] _ in
                self?.model.exportFailure = nil
                self?.export(.saveAs)
            }
        )
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
        installResponderChain()
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

        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                saveProject()
                guard !model.hasUnsavedChanges else { return }
                isClosingConfirmed = true
                sender.close()
            case .alertSecondButtonReturn:
                autosave.discard(for: fileURL)
                isClosingConfirmed = true
                sender.close()
            default:
                break
            }
        }
        return false
    }

    /// Offers work a previous session left behind — a crash, a force quit, a power cut.
    private func offerRecoveryIfAny() {
        guard let window, let recovered = autosave.read(for: fileURL) else { return }
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

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                model.replaceDocument(recovered.document)
                logger.info("Restored autosaved annotations")
            } else {
                autosave.discard(for: fileURL)
            }
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
        guard model.runningExport == nil else { return }
        let exportAction = action.exportAction
        model.beginExport(exportAction)

        let baseImage = baseImage
        let document = model.document
        let exportScale = model.exportScale
        let includeAnnotations = action != .copyWithoutAnnotations
        let renderer = renderer

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let image = try renderer.render(
                    baseImage: baseImage,
                    document: document,
                    includeAnnotations: includeAnnotations,
                    exportScale: exportScale
                )
                await MainActor.run {
                    guard let self else { return }
                    self.finishRenderedExport(action, image: image)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.model.failExport(exportAction, message: error.localizedDescription)
                    self?.logger.error(
                        "Export failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private func finishRenderedExport(_ action: EditorRootView.ExportAction, image: CGImage) {
        defer { model.endExport() }
        do {
            switch action {
            case .copy, .copyFlattened, .copyWithoutAnnotations:
                guard copyToClipboard(image) else {
                    model.failExport(action.exportAction, message: "The clipboard rejected the image.")
                    return
                }
                model.requestCopyToast()
            case .save:
                try save(image)
            case .saveAs:
                presentSaveAsSheet(for: image)
                return
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
            model.failExport(action.exportAction, message: error.localizedDescription)
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func retryExport(_ action: EditorExportAction) {
        model.exportFailure = nil
        export(action.rootAction)
    }
}
