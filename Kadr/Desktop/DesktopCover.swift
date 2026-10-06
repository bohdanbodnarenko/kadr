import AppKit
import ImageIO
import os
import Shared

/// Hides desktop icons by covering them with the wallpaper (docs/18 SH-4, docs/04 decision log).
///
/// Hiding used to write Finder's `CreateDesktop` and restart the Finder on every hide and
/// every show, then wait a fixed 250 ms for it to repaint. A restart interrupts a Finder
/// copy in progress, closes Finder windows' state, and leaves icons hidden after a crash.
/// A borderless window one level above the icons, showing the wallpaper, looks the same in
/// a capture, appears in the same turn, and dies with the process — nothing to restore.
///
/// The windows are ordinary capture content: not registered with
/// `CaptureExclusionRegistry`, and left at the default `sharingType`, because being in the
/// capture is their whole job.
@MainActor
final class DesktopCover {
    private let logger = KadrLog.logger(.app)
    private var windows: [NSWindow] = []
    private var screenObserver: (any NSObjectProtocol)?

    var isShowing: Bool {
        !windows.isEmpty
    }

    /// Covers every display's icons with its wallpaper.
    func show() {
        guard windows.isEmpty else { return }
        rebuild()
        // Only while shown: an idle agent observes nothing (rule 2).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func hide() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        tearDown()
    }

    private func rebuild() {
        tearDown()
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
        logger.info("Desktop cover on \(self.windows.count, privacy: .public) display(s)")
    }

    private func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.contents = Self.wallpaper(for: screen)
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    /// The display's wallpaper, decoded at the display's point size.
    ///
    /// Points, not pixels: the cover only has to hide icons, and a 5K wallpaper decoded at
    /// full size would be ~60 MB resident for as long as a user hide lasts (rule 2).
    static func wallpaper(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let longest = max(screen.frame.width, screen.frame.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longest)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
