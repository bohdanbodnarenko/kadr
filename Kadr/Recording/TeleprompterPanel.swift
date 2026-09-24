import AppKit
import OverlayKit
import Shared
import StudioSession

/// The floating script somebody reads from while recording (docs/08, teleprompter).
///
/// A `NonActivatingPanel`, because taking focus is the one thing it must never do: the
/// user is demonstrating another app, and a prompter that steals key status changes what
/// they are showing. It is movable, unlike Kadr's other overlays — a prompter has to sit
/// where the reader's eyes want it, which is usually just under the camera.
///
/// It registers itself for capture exclusion, but it is created after the recording's stream
/// has started, so the coordinator pushes the new exclusion list into the live stream right
/// after opening it (docs/17 T-REC-7). A window capture of somebody else's app never
/// contained it. A prompter that appears in the file is a recording somebody has to make
/// again.
@MainActor
final class TeleprompterPanel: NonActivatingPanel {
    private let scriptView = TeleprompterScriptView()

    /// Dragging anywhere moves it. There is no title bar to grab, and a panel that can only
    /// be moved by an edge nobody can see is a panel that cannot be moved.
    override var canBecomeKey: Bool {
        false
    }

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above ordinary windows but below the selection overlay, so starting a region
        // recording still puts the picker on top of the script.
        configureAsOverlay(level: .floating)
        isMovable = true
        isMovableByWindowBackground = true
        hasShadow = true

        let container = NSVisualEffectView(frame: frame)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        scriptView.autoresizingMask = [.width, .height]
        scriptView.frame = container.bounds
        container.addSubview(scriptView)
        contentView = container

        // Registered anyway, even though the bundle-wide exclusion already covers this.
        // The registry is what a future per-window filter reads, and a prompter is the last
        // window anybody would want to discover in a recording.
        CaptureExclusionRegistry.shared.register(self)
    }

    /// Taken off the exclusion list when the prompter closes.
    ///
    /// Called from the controller rather than from `deinit`: the registry holds weak
    /// references and sweeps dead ones on every read, so this is tidiness rather than
    /// correctness — and a `deinit` that reaches a main-actor singleton is a data race the
    /// compiler is right to refuse.
    func retire() {
        CaptureExclusionRegistry.shared.unregister(self)
    }

    // MARK: - Contents

    var script: TeleprompterScript {
        get { scriptView.script }
        set { scriptView.script = newValue }
    }

    /// Where the reader is, as a fractional word index.
    var position: Double {
        get { scriptView.position }
        set { scriptView.position = newValue }
    }

    var style: TeleprompterAppearance {
        get { scriptView.style }
        set { scriptView.style = newValue }
    }

    /// Puts the panel where it was last, or under the camera if it has never been placed.
    ///
    /// Top-centre because that is where a reader's eyes should be: a script at the bottom
    /// of the screen films somebody looking down, which is the exact problem a prompter is
    /// meant to solve. "Dock under camera" pins it just below the hardware notch
    /// (docs/16 REC-19e).
    func positionOnScreen(_ savedFrame: NSRect?, dockUnderCamera: Bool = false) {
        if dockUnderCamera, let screen = RecordingNotchScreen.notchScreen ?? ActiveScreen.resolve() {
            let metrics = RecordingNotchScreen.metrics
            let size = NSSize(width: min(760, screen.visibleFrame.width - 80), height: 220)
            setFrame(
                NSRect(
                    x: screen.frame.midX - size.width / 2,
                    y: screen.frame.maxY - metrics.height - size.height - 8,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
            return
        }
        if let savedFrame, NSScreen.screens.contains(where: { $0.frame.intersects(savedFrame) }) {
            setFrame(savedFrame, display: false)
            return
        }
        guard let screen = ActiveScreen.resolve() else { return }
        let size = NSSize(width: min(760, screen.visibleFrame.width - 80), height: 220)
        setFrame(
            NSRect(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 40,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }
}
