import AppKit
import Foundation

/// The windows a capture must not photograph (docs/09 U2.1, docs/10 R3.2).
///
/// Kadr's own overlays have to stay out of its own captures: a card sitting over the region
/// the user selected, or the selection overlay itself during a re-freeze, ends up in the
/// file. Excluding the whole application works and is blunt — it also makes it impossible
/// to screenshot Kadr's Settings window to file a bug about it.
///
/// A registry is the precise version. Overlays put themselves on it (every
/// `NonActivatingPanel` does this when it comes on screen); ordinary windows — Settings,
/// the editor, the history browser — do not, and are capturable like any other app's. The
/// capture engines look the IDs up as `SCWindow`s and pass them to
/// `SCContentFilter(display:excludingWindows:)`. Empty means exclude nothing.
///
/// References are weak, and dead ones are swept on every read: a panel that has been closed
/// has no window number worth excluding, and a registry that leaked its members would leak
/// every overlay Kadr ever showed.
@MainActor
public final class CaptureExclusionRegistry {
    /// Shared, because the capture paths and the windows that want excluding never meet.
    public static let shared = CaptureExclusionRegistry()

    private final class Entry {
        weak var window: NSWindow?

        init(window: NSWindow) {
            self.window = window
        }
    }

    private var entries: [Entry] = []

    public init() {}

    /// Adds a window to the exclusion list. Registering twice is harmless.
    public func register(_ window: NSWindow) {
        sweep()
        guard !entries.contains(where: { $0.window === window }) else { return }
        entries.append(Entry(window: window))
    }

    public func unregister(_ window: NSWindow) {
        entries.removeAll { $0.window === window || $0.window == nil }
    }

    /// The window numbers to keep out of a capture, as ScreenCaptureKit knows them.
    ///
    /// `NSWindow.windowNumber` is the same identifier `SCWindow.windowID` carries, which is
    /// what makes a registry of AppKit windows usable by a ScreenCaptureKit filter.
    public var excludedWindowIDs: Set<CGWindowID> {
        sweep()
        return Set(entries.compactMap { entry in
            guard let window = entry.window, window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
    }

    /// Whether any window is currently registered.
    public var isEmpty: Bool {
        sweep()
        return entries.isEmpty
    }

    /// Forgets windows that have gone.
    private func sweep() {
        entries.removeAll { $0.window == nil }
    }
}
