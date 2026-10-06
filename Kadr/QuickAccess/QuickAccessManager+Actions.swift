import AppKit
import CaptureCore
import ControlKit
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
            // The next keystroke is a paste somewhere else: it must not land on a card
            // (docs/18 OUT-1).
            self?.overlayPanel?.handBackKeyboard()
        }
        actions.save = { [weak self] in self?.save(item) }
        actions.saveAs = { [weak self] in self?.saveAs(item) }
        actions.delete = { [weak self] in self?.delete(item) }
        actions.deleteAvailable = canDelete(item)
        actions.dismiss = { [weak self] in self?.dismiss(item) }
        actions.resolveForDrag = { [weak self] in self?.resolveForDrag(item) }
        actions.dragCompleted = { [weak self] accepted in self?.dragCompleted(item, accepted: accepted) }
        actions.pathHandedOut = { [weak self] in self?.pathHandedOutItemIDs.insert(item.id) }
        actions.pin = { [weak self] in self?.pin(item) }
        actions.pinAvailable = true
        actions.annotate = { [weak self] in self?.annotate(item) }
        actions.annotateAvailable = editor.isAvailable
        actions.exportGIF = { [weak self] in self?.exportGIF(item) }
        actions.recognizeText = { [weak self] in self?.recognizeText(item) }
        actions.textAvailable = true
        actions.trim = { [weak self] in self?.trim(item) }
        actions.setHovered = { [weak self] hovering in self?.setHovered(item, hovering: hovering) }
        actions.keyboardFocused = { [weak self] in self?.lastHoveredItemID = item.id }
        actions.beginDrag = { [weak self] in self?.beginDrag(for: item) }
        actions.peek = { [weak self] in self?.setPeeking(true) }
        actions.compress = { [weak self] in self?.compress(item) }
        actions.rotate = { [weak self] in self?.transform(item, .rotateClockwise) }
        actions.flipHorizontal = { [weak self] in self?.transform(item, .flipHorizontal) }
        actions.flipVertical = { [weak self] in self?.transform(item, .flipVertical) }
        actions.scaleRetina = { [weak self] in self?.scaleRetina(item) }
        actions.trimAvailable = item.isVideo && editor.isAvailable
        actions.studio = { [weak self] in self?.openStudio(item) }
        // Asked once per card rather than on every redraw: it is a directory scan, and the
        // stack rebuilds every card's actions whenever anything on screen moves
        // (docs/17 T-OUT-13).
        actions.studioAvailable = item.isVideo && editor.isAvailable && hasStudioSession(item)
        actions.unavailableReason = { [weak self] cardAction in
            guard let self else { return nil }
            switch cardAction {
            case .annotate, .trim, .studio:
                return editor.isAvailable ? nil : .editorNotInstalled
            default:
                return nil
            }
        }
        actions.reportUnavailable = { [weak self] reason in
            self?.presentFeedback(.unavailable(reason))
        }
        return actions
    }

    /// Whether a recording still has its studio session, scanned once per card.
    func hasStudioSession(_ item: QuickAccessItem) -> Bool {
        if let known = studioSessionCache[item.id] {
            return known
        }
        let found = StudioSessionRecorder.session(forRecordingAt: item.fileURL) != nil
        studioSessionCache[item.id] = found
        return found
    }

    /// Opens a recording's studio session (docs/09 U3).
    ///
    /// The session rather than the movie: the movie alone opens for trimming, which is the
    /// same recording with none of the sidecar that makes it worth editing. Silent when
    /// there is no session, because the button is not offered in that case — this is the
    /// belt to that braces, for a session swept between the card appearing and the click.
    func openStudio(_ item: QuickAccessItem) {
        guard let session = StudioSessionRecorder.session(forRecordingAt: item.fileURL) else { return }
        openInEditor(session.directory, retiring: item)
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
        // Copy is otherwise invisible: say it happened, or say why it did not
        // (docs/17 T-OUT-13).
        if copyFile(at: url, isVideo: item.isVideo) {
            presentFeedback(.done(String(localized: "Copied")))
        } else {
            presentFeedback(.unavailable(.missingFile))
        }
        if keepOverlay {
            noteEngagement(with: item)
        }
    }

    /// Pinning counts as acting on a staged capture, so it is finalised first — a pin
    /// pointing at a file that the staging sweep later deletes would go blank.
    func pin(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        guard pins.pin(
            url,
            copy: { [weak self] fileURL in self?.copyFile(at: fileURL) },
            save: { [weak self] fileURL in self?.saveCopy(of: fileURL) },
            annotate: { [weak self] fileURL in self?.openInEditor(fileURL) },
            copyText: { [weak self] fileURL in self?.recognizeText(at: fileURL) },
            reveal: { [weak self] fileURL in self?.revealInFinder(fileURL) }
        ) else {
            presentFeedback(.unavailable(.missingFile))
            return
        }
    }

    /// Opens the capture in the editor. Annotating counts as acting on a staged file, so
    /// it is finalised first — the editor must not be pointed at a file the staging sweep
    /// will delete underneath it.
    func annotate(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        openInEditor(url, retiring: item)
    }

    /// Opens a capture in the editor, and retires its card (docs/03 §2).
    ///
    /// The card has done its job: the capture is now open in a window of its own, and a
    /// thumbnail of it in the corner is a second copy of something already on screen. It
    /// used to collapse the *whole stack* into the peek tab instead, which hid captures
    /// that had nothing to do with the edit and left a pill in the corner to be dealt with
    /// afterwards. Any other cards stay exactly as they are.
    ///
    /// Dismiss, not delete: the file is wherever the save policy put it, History has it,
    /// and Restore Recently Closed brings the card back.
    ///
    /// Only once the editor is actually up, never when it is merely asked for. A launch
    /// that does nothing — a build with no editor embedded, or a failure — must leave the
    /// card where it is, or the capture would vanish from the overlay with nothing opened
    /// to show for it. A sibling `.kadr` keeps window backdrops and auto-beautify editable
    /// (docs/03 §1.2).
    /// - Parameter card: the card this opening belongs to, when the URL is not the card's
    ///   own file. A recording opens its *session directory* in the studio, which matches
    ///   no card's `fileURL` — so the card was left sitting over the studio window.
    func openInEditor(_ url: URL, retiring card: QuickAccessItem? = nil) {
        let subject = card ?? items.first(where: { $0.fileURL == url })
        if let subject {
            noteEngagement(with: subject)
        }
        editor.open(CaptureProject.editorURL(for: url)) { [weak self] opened in
            guard let self else { return }
            guard opened else {
                // A launch that did nothing used to be silent (docs/17 T-OUT-13).
                presentFeedback(editor.isAvailable
                    ? .failure(String(localized: "Couldn't open the editor"))
                    : .unavailable(.editorNotInstalled))
                return
            }
            retireCard(subject)
        }
    }

    /// Dismisses the card whose capture has just opened in a window of its own.
    ///
    /// Checked against the live list rather than trusting the captured value: an editor
    /// takes a moment to appear, and the card may have been saved, deleted or swept in the
    /// meantime.
    func retireCard(_ card: QuickAccessItem?) {
        guard let card, items.contains(where: { $0.id == card.id }) else { return }
        dismiss(card)
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
            save: { [weak self] fileURL in self?.saveCopy(of: fileURL) },
            annotate: { [weak self] fileURL in self?.openInEditor(fileURL) },
            copyText: { [weak self] fileURL in self?.recognizeText(at: fileURL) },
            reveal: { [weak self] fileURL in self?.revealInFinder(fileURL) }
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
    func presentExternalFile(at url: URL, origin: QuickAccessOrigin = .external) -> Bool {
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
            displayName: url.lastPathComponent,
            origin: origin
        ))
        return true
    }

    /// Pins whatever is on the clipboard as a reference window (docs/03 §4).
    @discardableResult
    func pinClipboard() -> Bool {
        if let url = ClipboardMedia.fileURL(from: .general) {
            return pinFile(at: url)
        }
        guard let pngURL = ClipboardMedia.stillPNGFile(from: .general, in: pins.clipboardDirectory) else {
            return false
        }
        return pinFile(at: pngURL)
    }

    /// Opens whatever is on the clipboard as a card, or in the editor for a project.
    ///
    /// Images and movies both count: CleanShot 4.6 opens an MP4 copied onto the
    /// pasteboard the same way as a still. Plain text becomes a card so it can be pinned.
    @discardableResult
    func presentFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let url = ClipboardMedia.fileURL(from: pasteboard) {
            return presentExternalFile(at: url)
        }
        guard let destination = ClipboardMedia.stillPNGFile(from: pasteboard) else {
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
        openInEditor(url, retiring: item)
    }

    /// Re-encodes a capture smaller and copies it (docs/09 U2.4).
    ///
    /// Copies rather than replaces. Compression is lossy, and the case it exists for is
    /// "this needs to fit in a chat window" — a one-off need that must not cost the user
    /// the full-quality file they still have.
    func recognizeText(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = items.first { $0.id == item.id }?.fileURL ?? item.fileURL
        recognizeText(at: url, on: overlayPanel?.screen, card: item)
    }

    /// Recognises the text in a file, copies it, and shows what was found.
    ///
    /// Shared by cards, pins and `kadr` automation. Both card and pin offered this command
    /// with nothing behind it before (docs/07 M8).
    ///
    /// With a `card`, the card is busy while this runs, so auto-dismiss cannot take it
    /// mid-task (docs/16 OUT-16).
    func recognizeText(at url: URL, on screen: NSScreen? = nil, card: QuickAccessItem? = nil) {
        if let card {
            setActivity(.recognizingText, on: card)
        }
        Task { [weak self] in
            guard let self else { return }
            defer {
                if let card {
                    setActivity(nil, on: card)
                }
            }
            do {
                let recognition = try await textRecognizer.recognize(
                    fileAt: url,
                    preservingLineBreaks: settings.ocrPreservesLineBreaks
                )
                // Nothing to copy is a finding, not a toast of "0 characters"
                // (docs/17 T-OUT-13). The clipboard keeps what it had.
                guard !recognition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    presentFeedback(.unavailable(.other(String(localized: "No text found"))))
                    return
                }
                textRecognizer.copyToClipboard(recognition)
                let characters = recognition.text.count
                logger.info("Recognised \(characters, privacy: .public) characters from a card")
                let announcement = KadrText.string(
                    "Text copied, \(recognition.text.count) characters"
                )
                FeedbackAnnouncement.post(announcement)
                textToast.show(
                    text: recognition.text,
                    codes: recognition.codes,
                    table: recognition.table,
                    on: screen ?? ActiveScreen.resolve()
                )
            } catch {
                logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                presentFeedback(.failure(
                    ActionUnavailableReason.couldNotReadText.message,
                    retryTitle: String(localized: "Retry"),
                    retry: { [weak self] in self?.recognizeText(at: url, on: screen) }
                ))
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
