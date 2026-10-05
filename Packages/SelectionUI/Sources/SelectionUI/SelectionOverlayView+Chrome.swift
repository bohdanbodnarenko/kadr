import AppKit
import Shared

extension SelectionOverlayView {
    func updateHandles() {
        guard confirmsSelection,
              interaction.phase == .selected,
              let rect = interaction.rect,
              !rect.isEmpty
        else {
            handles.hide()
            return
        }
        handles.show(along: rect)
    }

    /// Runs on every mouse event, so it does as little as possible (T-CAP-12).
    ///
    /// The dimensions are kept current as the element's value, which VoiceOver reads when
    /// asked; an announcement and a rebuilt action list happen only when the phase, mode
    /// or hovered window changes — not 120 times a second while dragging.
    func refreshAccessibilityIfNeeded() {
        let rect = interaction.rect ?? .zero
        if rect != (lastAccessibilityRect ?? .zero) {
            lastAccessibilityRect = rect.isEmpty ? nil : rect
            accessibilityProxy?.setAccessibilityValue(accessibilitySummaryValue)
        }
        guard accessibilityPhaseToken != accessibilityAnnouncedPhase else { return }
        refreshAccessibilityElement(announcePhaseChange: true)
    }

    func oppositePoint(
        for corner: SelectionHandleLayerGroup.Corner,
        in rect: CGRect
    ) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    func resizedRect(
        from corner: SelectionHandleLayerGroup.Corner,
        anchor: CGPoint,
        to point: CGPoint
    ) -> CGRect {
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        return CGRect(
            x: min(anchor.x, clamped.x),
            y: min(anchor.y, clamped.y),
            width: max(1, abs(clamped.x - anchor.x)),
            height: max(1, abs(clamped.y - anchor.y))
        ).intersection(bounds)
    }

    /// Window mode dims everything and lifts the hovered window out of it.
    func updateWindowHighlight() {
        crosshairLayer.path = nil
        selectionBorderLayer.path = nil
        badgeBackgroundLayer.isHidden = true
        badgeTextLayer.isHidden = true
        loupe.hide()
        ruler.hide()

        let path = CGMutablePath()
        path.addRect(bounds)
        if let window = windowPick.hovered {
            let frame = window.frame.intersection(bounds)
            if !frame.isEmpty {
                path.addRoundedRect(in: frame, cornerWidth: 6, cornerHeight: 6)
            }
            windowHighlight.show(window, within: bounds)
        } else {
            windowHighlight.hide()
        }
        dimLayer.path = path
    }

    func updateDimming() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let rect = interaction.rect, !rect.isEmpty {
            // Even-odd fill turns the second rect into a hole, so the selection shows
            // through at full brightness (docs/03 §1.1).
            path.addRect(rect)
            selectionBorderLayer.path = CGPath(rect: rect, transform: nil)
        } else {
            selectionBorderLayer.path = nil
        }
        dimLayer.path = path
    }

    func updateCrosshair() {
        guard isPrecisionMode, interaction.phase != .selected, let pointer = interaction.pointer else {
            crosshairLayer.path = nil
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: pointer.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: pointer.x, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: pointer.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: pointer.y))
        crosshairLayer.path = path
    }

    /// The pixel ruler, which rides along with precision mode (docs/06 M21).
    func updateRuler() {
        guard isPrecisionMode, let rect = interaction.rect, !rect.isEmpty else {
            ruler.hide()
            return
        }
        ruler.show(along: rect)
    }

    /// A typed size is in points; say so, and on Retina say what it comes to in pixels, or
    /// "1280x720" silently yields a 2560×1440 file (docs/18 §4.2 P3).
    func typedSizeText() -> String {
        let scale = displayScale.factor
        guard let size = sizeEntry.size, scale != 1 else { return sizeEntry.displayText + " pt" }
        let pixels = "\(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded())) px"
        return "\(sizeEntry.displayText) pt (\(pixels))"
    }

    func updateBadge() {
        let measurement: String? = if !sizeEntry.isEmpty {
            typedSizeText()
        } else if let rect = interaction.rect, !rect.isEmpty {
            DimensionFormatter.text(for: rect, scale: displayScale)
        } else if isPrecisionMode, let pointer = interaction.pointer {
            String(format: "%.0f, %.0f", pointer.x, pointer.y)
        } else {
            nil
        }
        // The badge names the mode as well as the size, so Capture Text is unmistakable.
        // The eyedropper says so too, and lists its own keys — nobody guesses `F` and `X`.
        let modeBadge = isEyedropperMode ? "COLOUR  F: format  X: compare" : purpose.badge
        let text = [modeBadge, isEyedropperMode ? nil : measurement].compactMap(\.self)
            .joined(separator: "  ")
            .nilIfEmpty

        guard let text, let rect = interaction.rect ?? interaction.pointer.map({
            CGRect(origin: $0, size: .zero)
        }) else {
            badgeTextLayer.isHidden = true
            badgeBackgroundLayer.isHidden = true
            return
        }

        // Set only when it changed. Assigning `string` re-rasterises the layer, and a drag
        // along one axis leaves the text identical for most of its length.
        if badgeTextLayer.string as? String != text {
            badgeTextLayer.string = text
        }
        let width = Self.badgeWidth(for: text)

        // Below the selection by default, above it when there is no room.
        var origin = CGPoint(x: rect.midX - width / 2, y: rect.maxY + 8)
        if origin.y + Self.badgeHeight > bounds.maxY {
            origin.y = max(bounds.minY, rect.minY - Self.badgeHeight - 8)
        }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - width - 4)

        let frame = CGRect(origin: origin, size: CGSize(width: width, height: Self.badgeHeight))
        badgeBackgroundLayer.frame = frame
        badgeTextLayer.frame = frame.insetBy(dx: 0, dy: 3)
        badgeBackgroundLayer.isHidden = false
        badgeTextLayer.isHidden = false
    }

    func updateLoupe() {
        guard interaction.phase != .selected, let pointer = interaction.pointer else {
            loupe.hide()
            return
        }
        loupe.update(pointer: pointer, within: bounds, readout: eyedropperReadout)
    }
}
