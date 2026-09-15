import AppKit
import Foundation
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
        guard let panel = PinPanel(fileURL: fileURL, scale: scale) else {
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
            pendingRestore = record
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
        for pin in pins {
            pin.dismiss()
        }
        pins.removeAll()
        cascadeStep = 0
        areHidden = false
        persist()
    }

    private func close(_ panel: PinPanel) {
        guard let index = pins.firstIndex(where: { $0 === panel }) else { return }
        pins.remove(at: index).dismiss()
        persist()
    }

    private func persist() {
        guard !isRestoring, let store else { return }
        store.save(pins.map { panel in
            PinRecord(
                path: panel.fileURL.path,
                frame: panel.frame,
                alpha: Double(panel.alphaValue),
                clickThrough: panel.clickThroughEnabled
            )
        })
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
