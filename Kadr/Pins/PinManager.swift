import AppKit
import Foundation
import KeyboardShortcuts
import os
import OverlayKit
import Shared

/// Owns every pinned screenshot (docs/03 §4).
///
/// Pins are cheap on purpose: each holds a file URL and a texture sized to its window,
/// which is what makes the spec's budget — twenty pins inside 40 MB — achievable at all.
@MainActor
final class PinManager {
    private var pins: [PinPanel] = []
    private let logger = KadrLog.logger(.overlay)
    private let store: PinStore?
    private var isRestoring = false
    private var areHidden = false

    /// Where the next pin lands, so a run of pins cascades instead of stacking exactly.
    private var cascadeStep = 0
    private static let cascadeOffset: CGFloat = 24
    private static let cascadeWrap = 8

    private var pendingRestore: PinRecord?

    /// The debounced save, re-armed by every change until the pins sit still (PRD §8).
    ///
    /// Scrolling a pin's opacity, zooming it and nudging it each reported a geometry change
    /// per trackpad tick, and each change encoded pretty-printed JSON and wrote it
    /// atomically — on the main thread, dozens of times a second. The file is only read at
    /// the next launch, so the last state after a pause is the only one that matters.
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private let writer = PinStoreWriter()
    static let saveDebounce: Duration = .milliseconds(500)

    init(store: PinStore? = PinStore.applicationSupport()) {
        self.store = store
    }

    var count: Int {
        pins.count
    }

    var isEmpty: Bool {
        pins.isEmpty
    }

    var isHidden: Bool {
        areHidden
    }

    var fileURLs: [URL] {
        pins.map(\.fileURL)
    }

    /// Pins a capture. Returns false when the file cannot be read.
    @discardableResult
    func pin(
        _ fileURL: URL,
        copy: @escaping (URL) -> Void,
        save: @escaping (URL) -> Void,
        annotate: @escaping (URL) -> Void = { _ in },
        copyText: @escaping (URL) -> Void = { _ in },
        reveal: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) -> Bool {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        // A restored pin is built at its remembered frame, so the first decode is already
        // the right size rather than one texture for the default size and another 120 ms
        // later for the real one.
        guard let panel = PinPanel(fileURL: fileURL, scale: scale, frame: pendingRestore?.frame) else {
            logger.error("Could not pin \(fileURL.lastPathComponent, privacy: .public)")
            return false
        }

        panel.onCopy = { copy(fileURL) }
        panel.onSave = { save(fileURL) }
        panel.onReveal = { reveal(fileURL) }
        panel.onAnnotate = { annotate(fileURL) }
        panel.onCopyText = { copyText(fileURL) }
        panel.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.close(panel)
        }
        panel.onGeometryChanged = { [weak self] in
            self?.persist()
        }

        if let record = pendingRestore {
            panel.applyPersistedState(
                frame: record.frame,
                alpha: record.alpha,
                clickThrough: record.clickThrough
            )
            panel.orderFrontRegardless()
        } else {
            panel.present(at: nextOrigin(for: panel, on: screen))
        }

        if areHidden {
            setHidden(false)
        }

        pins.append(panel)
        let total = pins.count
        let name = fileURL.lastPathComponent
        logger.info("Pinned \(name, privacy: .public); \(total, privacy: .public) pin(s) open")
        persist()
        return true
    }

    /// Reopens pins that were showing when Kadr last quit (docs/03 §4 P2).
    func restore(
        copy: @escaping (URL) -> Void,
        save: @escaping (URL) -> Void,
        annotate: @escaping (URL) -> Void,
        copyText: @escaping (URL) -> Void,
        reveal: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        guard let store else { return }
        isRestoring = true
        defer {
            isRestoring = false
            persist()
        }
        for record in store.load() {
            let url = URL(fileURLWithPath: record.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            pendingRestore = record.clamped(to: NSScreen.screens.map(\.visibleFrame))
            _ = pin(
                url,
                copy: copy,
                save: save,
                annotate: annotate,
                copyText: copyText,
                reveal: reveal
            )
            pendingRestore = nil
        }
    }

    /// Hide / show every pin without closing them (CleanShot §11, §22.4).
    func toggleHidden() {
        setHidden(!areHidden)
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != areHidden else { return }
        areHidden = hidden
        for panel in pins {
            if hidden {
                panel.hideForStack()
            } else {
                panel.revealFromStack()
            }
        }
    }

    /// The "Close all pins" global command (docs/03 §4).
    func closeAll() {
        let urls = pins.map(\.fileURL)
        for pin in pins {
            pin.dismiss()
        }
        pins.removeAll()
        urls.forEach(discardClipboardCopy(of:))
        cascadeStep = 0
        areHidden = false
        persist()
    }

    private func close(_ panel: PinPanel) {
        guard let index = pins.firstIndex(where: { $0 === panel }) else { return }
        let closed = pins.remove(at: index)
        closed.dismiss()
        discardClipboardCopy(of: closed.fileURL)
        persist()
    }

    /// Where a pin of clipboard-only content should keep its bytes, or nil without a store.
    var clipboardDirectory: URL? {
        store?.clipboardDirectory
    }

    /// Deletes a clipboard pin's private copy once no pin shows it.
    private func discardClipboardCopy(of url: URL) {
        guard let store, store.ownsClipboardCopy(url), !pins.contains(where: { $0.fileURL == url }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Click-through (docs/17 T-OUT-9)

    /// Whether any pin is click-through right now, which is when ⌘⌥L is claimed.
    private(set) static var clickThroughHotkeyActive = false

    /// Toggles click-through on the pin under the pointer; failing that, the newest
    /// click-through pin; failing that, the newest pin.
    ///
    /// The pin's badge and VoiceOver hint promise ⌘⌥L, but the key used to live only in
    /// the pin's own menu — which a pin that ignores the mouse cannot open. The only way
    /// out was Close All Pins, and the state survived relaunch.
    func toggleClickThroughUnderPointer() {
        let pointer = NSEvent.mouseLocation
        let target = pins.last { $0.frame.contains(pointer) }
            ?? pins.last { $0.clickThroughEnabled }
            ?? pins.last
        target?.toggleClickThrough()
    }

    /// Claims ⌘⌥L while a pin is click-through, and gives it back when none is.
    static func applyClickThroughHotkey() {
        if clickThroughHotkeyActive {
            KeyboardShortcuts.enable(.togglePinClickThrough)
        } else {
            KeyboardShortcuts.disable(.togglePinClickThrough)
        }
    }

    private func updateClickThroughHotkey() {
        let active = pins.contains { $0.clickThroughEnabled }
        guard active != Self.clickThroughHotkeyActive else { return }
        Self.clickThroughHotkeyActive = active
        Self.applyClickThroughHotkey()
    }

    /// Asks for a save once the pins have been still for `saveDebounce`.
    private func persist() {
        updateClickThroughHotkey()
        guard !isRestoring, store != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveInBackground()
        }
    }

    /// Whether a change is waiting for its debounced save.
    var hasPendingSave: Bool {
        saveTask != nil
    }

    /// Snapshots now and writes off the main thread.
    private func saveInBackground() {
        saveTask = nil
        guard let store else { return }
        let records = snapshot()
        saveGeneration += 1
        let generation = saveGeneration
        let writer = writer
        Task.detached(priority: .utility) {
            writer.write(records, generation: generation, to: store)
        }
    }

    /// Writes any pending change now, on the calling thread.
    ///
    /// For quit, where there is no later: the process ends when
    /// `applicationWillTerminate` returns, so the debounce would never fire.
    func flushPendingSave() {
        guard let saveTask, let store else { return }
        saveTask.cancel()
        self.saveTask = nil
        saveGeneration += 1
        writer.write(snapshot(), generation: saveGeneration, to: store)
    }

    private func snapshot() -> [PinRecord] {
        pins.map { panel in
            PinRecord(
                path: panel.fileURL.path,
                frame: panel.frame,
                alpha: Double(panel.alphaValue),
                clickThrough: panel.clickThroughEnabled
            )
        }
    }

    /// Cascades pins down and right from the centre so a burst of them stays reachable.
    private func nextOrigin(for panel: PinPanel, on screen: NSScreen?) -> CGPoint {
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = CGFloat(cascadeStep % Self.cascadeWrap) * Self.cascadeOffset
        cascadeStep += 1

        let x = area.midX - panel.frame.width / 2 + offset
        let y = area.midY - panel.frame.height / 2 - offset
        return CGPoint(
            x: min(max(x, area.minX), area.maxX - panel.frame.width),
            y: min(max(y, area.minY), area.maxY - panel.frame.height)
        )
    }
}
