import AppKit
import AVFoundation
import AVKit
import MediaExport
import os
import Shared

/// One trim window over one recording (docs/03 §1.8).
///
/// In the editor process rather than the agent, for the same reason annotation is: an
/// `AVPlayer` over a screen recording decodes frames and holds them, and that memory has to
/// die with a window rather than accumulate in a process that never quits (docs/04 §1, §7).
///
/// The trim control itself is `AVPlayerView`'s. It is the one every Mac user already knows
/// from QuickTime — same handles, same ⌘⇧T, same behaviour when you scrub past an end — and
/// reimplementing it would have been a worse version of something already on the machine.
@MainActor
final class TrimWindowController: NSObject, NSWindowDelegate {
    enum OpenError: LocalizedError {
        case notPlayable(URL)

        var errorDescription: String? {
            switch self {
            case let .notPlayable(url):
                "“\(url.lastPathComponent)” is not a recording Kadr can trim."
            }
        }
    }

    private let fileURL: URL
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let trimmer = PassthroughVideoTrimmer()
    private let logger = KadrLog.logger(.app)

    private var window: NSWindow?

    var onClose: (() -> Void)?

    /// Whether this file is something to trim rather than annotate.
    static func handles(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }

    init(fileURL: URL) throws {
        guard Self.handles(fileURL), FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OpenError.notPlayable(fileURL)
        }
        self.fileURL = fileURL
        player = AVPlayer(url: fileURL)
        super.init()
    }

    func show() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.delegate = self
        window.isReleasedWhenClosed = false

        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.autoresizingMask = [.width, .height]

        let container = NSView(frame: window.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        playerView.frame = container.bounds
        container.addSubview(playerView)
        window.contentView = container

        window.toolbar = makeToolbar()
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Straight into trim mode: opening a recording from a card means the user already
        // decided they want to cut it, and one fewer click to get there is the whole point
        // of the Trim button existing (docs/03 §1.8).
        beginTrimming()
    }

    // MARK: - Trimming

    @objc func beginTrimming() {
        guard playerView.canBeginTrimming else {
            logger.info("This recording cannot be trimmed in place")
            return
        }
        // The completion handler is not main-actor isolated, so hop back before touching
        // the player or the window.
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton else { return }
            Task { @MainActor [weak self] in
                self?.exportTrimmedRange()
            }
        }
    }

    /// Writes the trimmed range to a new file beside the original.
    ///
    /// The handles set the player item's playable range, so that range — not the whole
    /// asset — is what the trim asks for.
    private func exportTrimmedRange() {
        guard let item = player.currentItem else { return }
        let range = TrimRange(
            start: CMTimeGetSeconds(item.reversePlaybackEndTime),
            end: CMTimeGetSeconds(item.forwardPlaybackEndTime)
        )
        let duration = CMTimeGetSeconds(item.duration)
        guard range.duration.isFinite, range.duration > 0 else { return }
        guard !range.isWhole(of: duration) else {
            logger.info("Trim covered the whole recording; nothing to write")
            return
        }

        let destination = PassthroughVideoTrimmer.destination(trimming: fileURL)
        Task { [weak self] in
            guard let self else { return }
            do {
                let written = try await trimmer.trim(movieAt: fileURL, to: range, destination: destination)
                logger.info("Wrote \(written.lastPathComponent, privacy: .public)")
                NSWorkspace.shared.activateFileViewerSelecting([written])
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "Kadr could not trim “\(fileURL.lastPathComponent)”."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Chrome

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "TrimToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        return toolbar
    }

    func windowWillClose(_ notification: Notification) {
        // Stop decoding before the window goes: an AVPlayer left playing keeps its
        // pipeline alive well past the window that showed it.
        player.pause()
        playerView.player = nil
        window = nil
        onClose?()
    }
}

extension TrimWindowController: NSToolbarDelegate {
    private static let trimItem = NSToolbarItem.Identifier("trim")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.trimItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.trimItem]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.trimItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Trim"
        item.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim")
        item.target = self
        item.action = #selector(beginTrimming)
        return item
    }
}
