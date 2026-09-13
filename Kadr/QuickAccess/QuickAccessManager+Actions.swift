import AppKit
import CaptureCore
import HistoryKit
import ImageIO
import MediaExport
import os
import OverlayKit
import SettingsKit
import Shared
import StudioSession
import UniformTypeIdentifiers

/// What a card's buttons do (docs/03 §2, §1.7, §1.8).
///
/// Split from the manager's own file because presenting cards and acting on them change
/// for different reasons — and because U0.5 added Trim and OCR to a file that was already
/// at its length budget.
@MainActor
extension QuickAccessManager {
    /// Opens a recording in the studio when a session still exists, otherwise the overlay.
    func openFromHistory(_ record: HistoryRecord) {
        guard let historyStore = history?.store else {
            presentFromHistory(record)
            return
        }
        let url = historyStore.fileURL(for: record)
        guard let sessionStore = StudioSessionRecorder.store() else {
            presentFromHistory(record)
            return
        }
        switch HistoryOpenRouting.destination(kind: record.kind, fileURL: url, store: sessionStore) {
        case let .studio(directory):
            history?.markAccessed(record)
            editor.open(directory)
        case .overlay:
            presentFromHistory(record)
        }
    }

    func actions(for item: QuickAccessItem) -> QuickAccessCardActions {
        var actions = QuickAccessCardActions()
        actions.copy = { [weak self] in
            self?.copy(item, keepOverlay: NSEvent.modifierFlags.contains(.option))
        }
        actions.save = { [weak self] in self?.save(item) }
        actions.saveAs = { [weak self] in self?.saveAs(item) }
        actions.delete = { [weak self] in self?.delete(item) }
        actions.dismiss = { [weak self] in self?.dismiss(item) }
        actions.resolveForDrag = { [weak self] in self?.resolveForDrag(item) }
        actions.dragCompleted = { [weak self] accepted in self?.dragCompleted(item, accepted: accepted) }
        actions.pin = { [weak self] in self?.pin(item) }
        actions.pinAvailable = true
        actions.annotate = { [weak self] in self?.annotate(item) }
        actions.annotateAvailable = editor.isAvailable
        actions.exportGIF = { [weak self] in self?.exportGIF(item) }
        actions.recognizeText = { [weak self] in self?.recognizeText(item) }
        actions.textAvailable = true
        actions.trim = { [weak self] in self?.trim(item) }
        actions.setHovered = { [weak self] hovering in self?.setHovered(item, hovering: hovering) }
        actions.beginDrag = { [weak self] in self?.beginDrag(for: item) }
        actions.peek = { [weak self] in self?.setPeeking(true) }
        actions.compress = { [weak self] in self?.compress(item) }
        actions.rotate = { [weak self] in self?.transform(item, .rotateClockwise) }
        actions.flipHorizontal = { [weak self] in self?.transform(item, .flipHorizontal) }
        actions.flipVertical = { [weak self] in self?.transform(item, .flipVertical) }
        actions.scaleRetina = { [weak self] in self?.scaleRetina(item) }
        actions.trimAvailable = item.isVideo && editor.isAvailable
        actions.studio = { [weak self] in self?.openStudio(item) }
        // Asked once, when the card is built, rather than on every redraw: it is a
        // directory scan, and a card redraws whenever anything on screen moves.
        actions.studioAvailable = item.isVideo
            && editor.isAvailable
            && StudioSessionRecorder.session(forRecordingAt: item.fileURL) != nil
        return actions
    }

    /// Opens a recording's studio session (docs/09 U3).
    ///
    /// The session rather than the movie: the movie alone opens for trimming, which is the
    /// same recording with none of the sidecar that makes it worth editing. Silent when
    /// there is no session, because the button is not offered in that case — this is the
    /// belt to that braces, for a session swept between the card appearing and the click.
    func openStudio(_ item: QuickAccessItem) {
        guard let session = StudioSessionRecorder.session(forRecordingAt: item.fileURL) else { return }
        openInEditor(session.directory)
    }

    func exportGIF(_ item: QuickAccessItem) {
        exportGIF(item, confirm: true)
    }

    /// Turns a recording into a GIF. Dedicated GIF capture skips the confirm unless
    /// the encoder had to clip the take (docs/03 §1.8, CleanShot §13.6).
    ///
    /// The encode happens in the helper process, so the agent never holds a single frame
    /// of it (docs/04 §1).
    func exportGIF(_ item: QuickAccessItem, confirm: Bool) {
        let destination = item.fileURL.deletingPathExtension().appendingPathExtension("gif")
        Task { [weak self] in
            guard let self else { return }
            defer { vision.disconnect() }

            do {
                let estimate = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path,
                    estimateOnly: true
                ))
                if confirm || estimate.isClipped {
                    guard confirmExport(estimate) else { return }
                }

                let result = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path
                ))
                guard let path = result.path else { return }
                let gifURL = URL(fileURLWithPath: path)
                logger.info("Exported \(gifURL.lastPathComponent, privacy: .public)")
                presentExternalFile(at: gifURL)
                NSWorkspace.shared.activateFileViewerSelecting([gifURL])
            } catch {
                logger.error("GIF export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Shows the estimate before committing, because a large GIF takes real time to make.
    ///
    /// The estimate carries the plan the encoder settled on, so a recording too long to
    /// hold in memory says so here rather than silently producing a shorter GIF than the
    /// user expected (docs/07 M10).
    func confirmExport(_ estimate: GIFResponse) -> Bool {
        let size = ByteCountFormatter.string(fromByteCount: Int64(estimate.byteCount), countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Export this recording as a GIF?"
        var detail = "The GIF will be roughly \(size). GIFs are much larger than "
            + "video, so long recordings get big quickly."
        if estimate.isClipped {
            let seconds = Int(estimate.encodedSeconds.rounded())
            detail += "\n\nThis recording is too long to turn into one GIF, so the export "
                + "will cover the first \(seconds) seconds. Trim it first to choose which part."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func copy(_ item: QuickAccessItem) {
        copy(item, keepOverlay: false)
    }

    /// Copies the capture. Option keeps the card even when a timeout would take it
    /// (CleanShot §6.2). Copy never dismisses on its own — docs/03 §2 leaves that to Save
    /// and drag — but Option claims the card so auto-close cannot steal it.
    func copy(_ item: QuickAccessItem, keepOverlay: Bool) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        copyFile(at: url, isVideo: item.isVideo)
        if keepOverlay {
            noteEngagement(with: item)
        }
    }

    /// Pinning counts as acting on a staged capture, so it is finalised first — a pin
    /// pointing at a file that the staging sweep later deletes would go blank.
    func pin(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        pins.pin(
            url,
            copy: { [weak self] fileURL in self?.copyFile(at: fileURL) },
            save: { [weak self] fileURL in self?.revealInFinder(fileURL) },
            annotate: { [weak self] fileURL in self?.openInEditor(fileURL) },
            copyText: { [weak self] fileURL in self?.recognizeText(at: fileURL) }
        )
    }

    /// Opens the capture in the editor. Annotating counts as acting on a staged file, so
    /// it is finalised first — the editor must not be pointed at a file the staging sweep
    /// will delete underneath it.
    func annotate(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        openInEditor(url)
    }

    /// Opens the editor and tucks the cards into the peek tab (docs/03 §2).
    ///
    /// The cards hide rather than sit over the editor. A peek tab stays in the same
    /// corner so the user can bring them back without waiting for the editor to quit.
    /// Opening the editor is high-intent: that card stops auto-dismissing.
    func openInEditor(_ url: URL) {
        if let item = items.first(where: { $0.fileURL == url }) {
            noteEngagement(with: item)
        }
        // Tucked away when the editor is actually up, not when it is asked for (docs/03 §2).
        //
        // This used to collapse first and launch afterwards, so a launch that did nothing —
        // a build with no editor embedded, or a failure — left the stack in the peek tab
        // with nothing to come back from. The tab reads "1 Screenshot" and stays: the only
        // thing that expands it again is the editor process terminating, and none started.
        // A sibling `.kadr` keeps window backdrops and auto-beautify editable (docs/03 §1.2).
        editor.open(CaptureProject.editorURL(for: url)) { [weak self] opened in
            guard let self, opened, !items.isEmpty else { return }
            setPeeking(true)
        }
    }

    /// Pins a file automation named, or a capture automation just took (docs/03 §8.4).
    ///
    /// Takes a URL rather than a card because `kadr pin --path …` names a file the
    /// overlay has never seen. Returns false when the file cannot be read as an image.
    @discardableResult
    func pinFile(at url: URL) -> Bool {
        pins.pin(
            finalized(url),
            copy: { [weak self] fileURL in self?.copyFile(at: fileURL) },
            save: { [weak self] fileURL in self?.revealInFinder(fileURL) },
            annotate: { [weak self] fileURL in self?.openInEditor(fileURL) },
            copyText: { [weak self] fileURL in self?.recognizeText(at: fileURL) }
        )
    }

    /// Opens a file in the editor, for `kadr annotate --path …` (docs/03 §8.4).
    func annotateFile(at url: URL) {
        openInEditor(finalized(url))
    }

    /// Saves every visible card to the save folder and dismisses them (CleanShot §6.3).
    ///
    /// Bulk save is always silent: asking once per card would be worse than not saving at
    /// all. A snapshot of `items` is taken first so dismissals during the loop cannot skip
    /// cards still waiting to be saved.
    func saveAll() {
        dismissCardsSequentially(Array(items), finalizeBeforeDismiss: true)
    }

    /// Hides the cards without dismissing them, so they do not appear in the next capture
    /// (CleanShot §6.3). A new capture brings them back.
    func toggleHidden() {
        setHidden(!areHidden)
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != areHidden else { return }
        areHidden = hidden
        if hidden {
            overlayPanel?.orderOut(nil)
        } else {
            restack()
        }
    }

    /// Puts an existing file on the overlay, for `add-quick-access-overlay` (CleanShot §20.7).
    @discardableResult
    func presentExternalFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        present(QuickAccessItem(
            fileURL: url,
            isStaged: false,
            pixelSize: Self.pixelSize(of: url) ?? PixelSize(width: 0, height: 0),
            scale: Self.scale(of: url),
            capturedAt: Date(),
            displayID: nil,
            isVideo: isVideo,
            historyKind: isVideo ? .video : .image,
            displayName: url.lastPathComponent
        ))
        return true
    }

    /// Opens whatever is on the clipboard as a card, or in the editor for a project.
    ///
    /// Images and movies both count: CleanShot 4.6 opens an MP4 copied onto the
    /// pasteboard the same way as a still.
    @discardableResult
    func presentFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let url = ClipboardMedia.fileURL(from: pasteboard) {
            return presentExternalFile(at: url)
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            return false
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kadr-clipboard-\(UUID().uuidString).png")
        do {
            try png.write(to: destination, options: .atomic)
        } catch {
            logger.error("Could not write the clipboard image: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return presentExternalFile(at: destination)
    }

    /// Pixel size from ImageIO headers, so a card for an external file does not decode it.
    static func pixelSize(of url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return PixelSize(width: width, height: height)
    }

    /// DPI tag → backing scale, so an external file can still offer Scale Retina to 1×.
    static func scale(of url: URL) -> DisplayScale {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .oneToOne }
        return ImageTransformer.scale(of: source)
    }

    /// The permanent home of a file automation named, finalising it if it is staged.
    ///
    /// `kadr pin --path …` and `kadr annotate --path …` take a path, not a card, so they
    /// bypassed the card's finalise-on-first-action step entirely. A pin left on a staged
    /// capture went blank when the 24-hour sweep ran (docs/07 M11).
    ///
    /// Falls back to the path as given: a file that is not staged, or that cannot be
    /// moved, is still better shown than refused.
    func finalized(_ url: URL) -> URL {
        if let item = items.first(where: { $0.fileURL == url }) {
            finalizeIfStaged(item)
            return items.first { $0.id == item.id }?.fileURL ?? url
        }
        guard output.isStaged(url), let moved = output.finalizeStaged(url) else { return url }
        CaptureProject.move(from: url, to: moved)
        return moved
    }

    /// Opens a recording in the trim window (docs/03 §1.8).
    ///
    /// Trimming is an edit, so like Annotate it finalises a staged capture first — the
    /// trim writes beside the original, and the original must not be swept away under it.
    func trim(_ item: QuickAccessItem) {
        guard item.isVideo else { return }
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        openInEditor(url)
    }

    /// Re-encodes a capture smaller and copies it (docs/09 U2.4).
    ///
    /// Copies rather than replaces. Compression is lossy, and the case it exists for is
    /// "this needs to fit in a chat window" — a one-off need that must not cost the user
    /// the full-quality file they still have.
    func compress(_ item: QuickAccessItem) {
        guard !item.isVideo else { return }
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        let format = settings.compressionFormat
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-compressed-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)

        Task { [weak self] in
            guard let self else { return }
            defer { vision.disconnect() }
            do {
                let response = try await vision.compressImage(CompressRequest(
                    sourcePath: url.path,
                    destinationPath: destination.path,
                    targetBytes: settings.compressionTargetBytes,
                    format: format.rawValue
                ))
                guard response.isWorthwhile else {
                    // A screenshot of flat colour re-encodes larger than its PNG. Saying
                    // so beats putting a bigger file on the clipboard and calling it
                    // compressed.
                    try? FileManager.default.removeItem(at: destination)
                    showCompressionResult(nil, for: item)
                    return
                }
                copyFile(at: URL(fileURLWithPath: response.path))
                showCompressionResult(response, for: item)
            } catch {
                logger.error("Compression failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: destination)
                showCompressionResult(nil, for: item)
            }
        }
    }

    /// Puts the savings on the card, or says there were none.
    private func showCompressionResult(_ response: CompressResponse?, for item: QuickAccessItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].compressionSavings = response.map(\.savingsFraction)
        items[index].wasCompressed = true
        // No redraw to ask for: the stack observes `items`, so the badge appears with the
        // mutation. Rebuilding a card's root view by hand is what the old one-panel-per-card
        // overlay needed, because a hosting view holds a value rather than a reference.
    }

    /// Recognises the text in a card's capture and copies it (docs/03 §1.7, §2).
    ///
    /// Acting on a staged capture finalises it first, exactly like Copy or Pin: the user
    /// has done something with this screenshot, so it stops being disposable.
    func recognizeText(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        recognizeText(at: url, on: overlayPanel?.screen)
    }

    /// Recognises the text in a file, copies it, and shows what was found.
    ///
    /// Shared by cards, pins and `kadr` automation. Both card and pin offered this command
    /// with nothing behind it before (docs/07 M8).
    func recognizeText(at url: URL, on screen: NSScreen? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let recognition = try await textRecognizer.recognize(
                    fileAt: url,
                    preservingLineBreaks: settings.ocrPreservesLineBreaks
                )
                textRecognizer.copyToClipboard(recognition)
                let characters = recognition.text.count
                logger.info("Recognised \(characters, privacy: .public) characters from a card")
                textToast.show(
                    text: recognition.text,
                    codes: recognition.codes,
                    table: recognition.table,
                    on: screen ?? NSScreen.main
                )
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // Puts a capture on the clipboard as what it actually is (docs/07 M1).
    //
    // Announcing every file as PNG meant a JPEG or HEIC pasted as garbage, and a
    // recording put hundreds of megabytes of MP4 on the pasteboard under an image type
    // no app could read. A video goes on as a file reference, which is what Finder, Mail
    // and Messages expect.
}
