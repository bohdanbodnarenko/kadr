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
final class EditorWindowController: NSResponder, NSWindowDelegate, NSMenuItemValidation,
    RedactionAssisting, SubjectLifting {
    enum OpenError: LocalizedError {
        case unreadableImage(URL)

        var errorDescription: String? {
            switch self {
            case let .unreadableImage(url):
                "“\(url.lastPathComponent)” is not an image Kadr can read."
            }
        }
    }

    /// The file this window represents. Rebinds after a save or Save As (T-ED-1).
    var documentURL: URL
    /// Where ⌘S writes once the user has picked a destination with Save As; until then the
    /// targets are planned from `documentURL` and the agent's settings.
    var chosenSaveTargets: EditorSaveTargets?
    let baseImage: CGImage
    /// The immutable capture as PNG, worked out once and off the main actor, so neither
    /// opening the window nor autosave re-encodes a 5K image (docs/10 R2.6).
    let basePNG: BaseImagePNG
    /// Whether the capture's transparent margin still has to be measured.
    let needsVisibleBounds: Bool
    /// The measurement, once it has been made.
    var measuredVisibleBounds: CGRect?
    let model: EditorDocumentModel
    let canvasSession = EditorCanvasSession()
    let renderer = AnnotationExportRenderer()
    let logger = KadrLog.logger(.app)
    let vision = VisionClient()

    var window: NSWindow?
    private var hostingView: NSView?

    /// Keeps a recoverable copy while the user works (docs/07 M7).
    let autosave = EditorAutosave()
    var autosaveTask: Task<Void, Never>?
    /// The coalesced reaction to a document change, while one is pending.
    var pendingChangeTask: Task<Void, Never>?
    /// Writes the style memory once it has been still for a moment.
    var styleMemoryTask: Task<Void, Never>?
    /// What was last written to the defaults, so an unchanged memory is not re-encoded.
    var savedStyleMemory: StyleMemory?
    /// False once this window has discarded any autosave and not written a new one, so a
    /// clean document does not delete a file that is not there on every change.
    var autosaveMayExist = true
    /// True once the user has been asked about closing, so the second close goes through.
    var isClosingConfirmed = false
    /// How long the document has to be still before a copy is written.
    static let autosaveSettleMilliseconds = 1500
    /// How long the style memory has to be still before it is written to the defaults.
    static let styleMemorySettleMilliseconds = 500

    var onClose: (() -> Void)?

    init(fileURL documentURL: URL) throws {
        self.documentURL = documentURL

        // `.kadr` carries its own annotations; anything else is a fresh capture.
        if documentURL.pathExtension.lowercased() == KadrDocumentFile.fileExtension {
            let contents = try KadrDocumentFile.read(from: documentURL)
            guard let image = Self.decodeImage(from: contents.baseImagePNG) else {
                throw OpenError.unreadableImage(documentURL)
            }
            baseImage = image
            basePNG = BaseImagePNG(image: image, png: contents.baseImagePNG)
            // Documents saved before the window was measured, and the agent's auto-beautify
            // projects (the agent cannot read pixels this way), are measured after open.
            needsVisibleBounds = contents.document.baseImage.visibleBounds == nil
            model = EditorDocumentModel(document: contents.document)
            if let exportScale = contents.exportScale {
                model.exportScale = CGFloat(exportScale)
            }
        } else {
            // Read once: decoded from these bytes, and kept as the base PNG when that is
            // what they already are. Kept in memory rather than mapped, because saving a
            // flattened image may overwrite this very file.
            guard let bytes = try? Data(contentsOf: documentURL),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw OpenError.unreadableImage(documentURL)
            }
            baseImage = image
            basePNG = BaseImagePNG(image: image, png: BaseImagePNG.isPNG(source) ? bytes : nil)

            // Captures are written with a DPI tag that records their scale, so the editor
            // shows a Retina screenshot at the size the user selected rather than double.
            let scale = Self.scale(of: source)
            let size = CGSize(
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
            // A window captured with its shadow is the window plus a transparent margin;
            // Beautify composes the window, not the margin (docs/03 §3 P2). Measured after
            // open, off the main actor: it is a full decode of the capture.
            needsVisibleBounds = true
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
        guard needsVisibleBounds else {
            present()
            return
        }
        // A beautified project composes the window inside the capture, so its canvas size
        // depends on the measurement: wait for it rather than open at one size and jump to
        // another. Anything else opens now and picks the measurement up when it lands.
        let waits = model.document.beautify != nil
        if !waits {
            present()
        }
        let image = baseImage
        let scale = model.document.baseImage.scale
        Task { [weak self] in
            let bounds = await Task.detached(priority: .userInitiated) {
                CaptureVisibleBounds.find(in: image, scale: scale)
            }.value
            guard let self else { return }
            measuredVisibleBounds = bounds
            model.adoptVisibleBounds(bounds)
            if waits {
                present()
            }
        }
    }

    private func present() {
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
            },
            onDelete: { [weak self] in
                self?.confirmMoveToTrash()
            }
        )
        let hosting = NSHostingView(rootView: root)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: EditorWindowGeometry.minSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        Self.applyContract(to: window, hosting: hosting, title: documentURL.lastPathComponent)
        // The title-bar proxy icon: dragging it hands the file to another app (docs/03 §3).
        // Never the `.kadr`, which holds the un-redacted original (docs/18 ED-3).
        window.representedURL = proxyURL
        window.isDocumentEdited = model.hasUnsavedChanges
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
        // A second capture opened while one is up cascades from it, rather than landing on
        // the same saved frame exactly on top of it (T-ED-12). Only one window can own the
        // autosave name, so the others simply do not remember their frames.
        if let neighbour = NSApp.orderedWindows.first(where: {
            $0 !== window && $0.isVisible && $0.delegate is EditorWindowController
        }) {
            let topLeft = CGPoint(x: neighbour.frame.minX, y: neighbour.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        }
        window.setFrameAutosaveName(autosaveName)

        self.window = window
        hostingView = hosting
        installResponderChain()
        window.makeKeyAndOrderFront(nil)

        offerRecoveryIfAny()
        trackChangesForAutosave()
        provideFlattenedDragOut()
    }

    // MARK: - Unsaved work (docs/07 M7)

    /// Closing used to discard the annotations silently, with no prompt and no copy.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingConfirmed, model.hasUnsavedChanges else { return true }
        reviewUnsavedChanges { [weak self] proceed in
            guard proceed, let self else { return }
            isClosingConfirmed = true
            sender.close()
        }
        return false
    }

    /// Asks Save / Don't Save / Cancel as a sheet, and reports whether the window may go:
    /// true once the document is saved or the user chose to discard it (docs/03:171).
    ///
    /// Shared by closing the window and by quitting (T-ED-7).
    func reviewUnsavedChanges(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let window, model.hasUnsavedChanges else {
            completion(true)
            return
        }
        window.makeKeyAndOrderFront(nil)

        let alert = NSAlert()
        alert.messageText = String(localized: "Save your changes to “\(documentURL.lastPathComponent)”?")
        alert.informativeText = String(localized: "Save writes the flattened image and a project file so the ")
            + "annotations stay editable."
        alert.addButton(withTitle: String(localized: "Save"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don't Save"))
        dontSave.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.alertStyle = .warning

        let responder = FocusRestoration.capture(from: window)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                saveBeforeClosing(completion)
            case .alertSecondButtonReturn:
                autosave.discard(for: documentURL)
                completion(true)
            default:
                FocusRestoration.restore(responder, in: window)
                completion(false)
            }
        }
    }

    /// Renders and saves, then reports whether it worked. An imported copy asks where to
    /// save, as ⌘S does (T-ED-9).
    private func saveBeforeClosing(_ completion: @escaping @MainActor (Bool) -> Void) {
        let baseImage = baseImage
        let document = model.document
        let exportScale = model.exportScale
        let renderer = renderer
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try renderer.render(
                        baseImage: baseImage,
                        document: document,
                        includeAnnotations: true,
                        exportScale: exportScale
                    )
                }
            }.value
            guard let self else { return }
            do {
                let image = try result.get()
                if editsImportedCopy {
                    presentSaveAsSheet(for: image) { [weak self] saved in
                        completion(saved && self?.model.hasUnsavedChanges == false)
                    }
                    return
                }
                try save(image)
                completion(true)
            } catch {
                model.failExport(.save, message: error.localizedDescription)
                completion(false)
            }
        }
    }

    /// The title, the window floor and the accessible name every annotation window shares.
    private static func applyContract(to window: NSWindow, hosting: NSView, title: String) {
        window.title = title
        // The floor the layout contract promises; without it the window could be dragged
        // smaller than the toolbar and inspector fit in (docs/14 UX-05).
        window.contentMinSize = EditorWindowGeometry.minSize
        // The hosting view is the group VoiceOver lands in first; unnamed, the audit
        // flags it and VoiceOver reads only "group" (docs/18 UX-02).
        hosting.setAccessibilityLabel(String(localized: "Annotation editor"))
    }

    func windowWillClose(_ notification: Notification) {
        autosaveTask?.cancel()
        autosaveTask = nil
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        flushStyleMemory()
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

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let image = try renderer.render(
                    baseImage: baseImage,
                    document: document,
                    includeAnnotations: includeAnnotations,
                    exportScale: exportScale
                )
                await MainActor.run {
                    // Cancelled while rendering: the result goes nowhere, and a newer export
                    // may already own the chrome (docs/18 §4.1 P3).
                    guard let self, !Task.isCancelled else { return }
                    self.finishRenderedExport(action, image: image)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled else { return }
                    self?.model.failExport(exportAction, message: error.localizedDescription)
                    self?.logger.error(
                        "Export failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        model.exportCancellation = { task.cancel() }
    }

    private func finishRenderedExport(_ action: EditorRootView.ExportAction, image: CGImage) {
        defer { model.endExport() }
        do {
            switch action {
            case .copy, .copyFlattened, .copyWithoutAnnotations:
                let annotations = action == .copy ? model.encodedSelection() : nil
                guard copyToClipboard(image, annotations: annotations) else {
                    model.failExport(action.exportAction, message: "The clipboard rejected the image.")
                    return
                }
                model.requestCopyToast()
            case .save where editsImportedCopy:
                presentSaveAsSheet(for: image)
                return
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
