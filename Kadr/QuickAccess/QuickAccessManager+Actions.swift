import AppKit
import CaptureCore
import HistoryKit
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
    func actions(for item: QuickAccessItem) -> QuickAccessCardActions {
        var actions = QuickAccessCardActions()
        actions.copy = { [weak self] in self?.copy(item) }
        actions.save = { [weak self] in self?.save(item) }
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
        actions.textAvailable = !item.isVideo
        actions.trim = { [weak self] in self?.trim(item) }
        actions.engage = { [weak self] in self?.noteEngagement(with: item) }
        actions.compress = { [weak self] in self?.compress(item) }
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

    /// Turns a recording into a GIF, asking first if it is going to be large (docs/03 §1.8).
    ///
    /// The encode happens in the helper process, so the agent never holds a single frame
    /// of it (docs/04 §1).
    func exportGIF(_ item: QuickAccessItem) {
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
                guard confirmExport(estimate) else { return }

                let result = try await vision.encodeGIF(GIFRequest(
                    sourcePath: item.fileURL.path,
                    destinationPath: destination.path
                ))
                guard let path = result.path else { return }
                logger.info("Exported \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
        copyFile(at: url, isVideo: item.isVideo)
    }

    /// Pinning counts as acting on a staged capture, so it is finalised first — a pin
    /// pointing at a file that the staging sweep later deletes would go blank.
    func pin(_ item: QuickAccessItem) {
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
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
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
        openInEditor(url)
    }

    /// Opens the editor and gets the cards out of its way (docs/09 U2.1).
    ///
    /// The cards collapse to an edge tab rather than hiding: an editor window is where the
    /// user is now, and a stack of cards over it is in the way — but hiding them means
    /// putting them back at the right moment, and either mistake loses a card or flashes it
    /// over the window.
    func openInEditor(_ url: URL) {
        setPeeking(true)
        editor.open(url)
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

    /// The permanent home of a file automation named, finalising it if it is staged.
    ///
    /// `kadr pin --path …` and `kadr annotate --path …` take a path, not a card, so they
    /// bypassed the card's finalise-on-first-action step entirely. A pin left on a staged
    /// capture went blank when the 24-hour sweep ran (docs/07 M11).
    ///
    /// Falls back to the path as given: a file that is not staged, or that cannot be
    /// moved, is still better shown than refused.
    func finalized(_ url: URL) -> URL {
        if let item = panels.first(where: { $0.item.fileURL == url })?.item {
            finalizeIfStaged(item)
            return panels.first { $0.item.id == item.id }?.item.fileURL ?? url
        }
        guard output.isStaged(url), let moved = output.finalizeStaged(url) else { return url }
        return moved
    }

    /// Opens a recording in the trim window (docs/03 §1.8).
    ///
    /// Trimming is an edit, so like Annotate it finalises a staged capture first — the
    /// trim writes beside the original, and the original must not be swept away under it.
    func trim(_ item: QuickAccessItem) {
        guard item.isVideo else { return }
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
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
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
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
        guard let index = panels.firstIndex(where: { $0.item.id == item.id }) else { return }
        panels[index].item.compressionSavings = response.map(\.savingsFraction)
        panels[index].item.wasCompressed = true
        let entry = panels[index]
        entry.panel.refresh(item: entry.item, settings: settings, actions: actions(for: entry.item))
    }

    /// Recognises the text in a card's capture and copies it (docs/03 §1.7, §2).
    ///
    /// Acting on a staged capture finalises it first, exactly like Copy or Pin: the user
    /// has done something with this screenshot, so it stops being disposable.
    func recognizeText(_ item: QuickAccessItem) {
        guard !item.isVideo else { return }
        finalizeIfStaged(item)
        let url = panels.first { $0.item.id == item.id }?.item.fileURL ?? item.fileURL
        recognizeText(at: url, on: panels.first { $0.item.id == item.id }?.panel.screen)
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
