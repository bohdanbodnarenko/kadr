import AppKit
import Foundation
import os
import Shared

/// Owns every pinned screenshot (docs/03 §4).
///
/// Pins are cheap on purpose: each holds a file URL and a texture sized to its window,
/// which is what makes the spec's budget — twenty pins inside 40 MB — achievable at all.
@MainActor
final class PinManager {
    private var pins: [PinPanel] = []
    private let logger = KadrLog.logger(.overlay)

    /// Where the next pin lands, so a run of pins cascades instead of stacking exactly.
    private var cascadeStep = 0
    private static let cascadeOffset: CGFloat = 24
    private static let cascadeWrap = 8

    var count: Int {
        pins.count
    }

    var isEmpty: Bool {
        pins.isEmpty
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
        copyText: @escaping (URL) -> Void = { _ in }
    ) -> Bool {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        guard let panel = PinPanel(fileURL: fileURL, scale: scale) else {
            logger.error("Could not pin \(fileURL.lastPathComponent, privacy: .public)")
            return false
        }

        panel.onCopy = { copy(fileURL) }
        panel.onSave = { save(fileURL) }
        panel.onAnnotate = { annotate(fileURL) }
        panel.onCopyText = { copyText(fileURL) }
        panel.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.close(panel)
        }

        panel.present(at: nextOrigin(for: panel, on: screen))
        pins.append(panel)
        // Bound to a local: a log message is an autoclosure, so a property reference in
        // it would need an explicit `self.` that SwiftFormat strips again.
        let total = pins.count
        let name = fileURL.lastPathComponent
        logger.info("Pinned \(name, privacy: .public); \(total, privacy: .public) pin(s) open")
        return true
    }

    /// The "Close all pins" global command (docs/03 §4).
    func closeAll() {
        for pin in pins {
            pin.dismiss()
        }
        pins.removeAll()
        cascadeStep = 0
    }

    private func close(_ panel: PinPanel) {
        guard let index = pins.firstIndex(where: { $0 === panel }) else { return }
        pins.remove(at: index).dismiss()
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
