import AppKit
import CaptureCore
import os
import SelectionUI
import SettingsKit
import Shared

/// Direct (no overlay) capture paths used by automation and the fullscreen hotkey
/// (docs/03 §1.3, §8.4, CleanShot §20).
@MainActor
extension AreaCaptureCoordinator {
    /// Captures every display with no overlay at all (docs/03 §1.3).
    func captureAllDisplays() {
        rememberBeautifySkip()
        if captureHeldFreeze() { return }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        inFlight?.cancel()
        let seconds = timerSeconds
        timer.run(seconds: seconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    await engine.setDynamicRange(settings.captureDynamicRange)
                    // Before the pixels, not after: hiding the icons or swapping the
                    // wallpaper afterwards leaves them in the shot and restarts the Finder
                    // for nothing (docs/07 H3).
                    await hygiene?.beginCaptureAndSettle()
                    await CaptureExclusionPush.into(engine)
                    let captures = try await engine.captureAllDisplays(
                        includesCursor: includesCursor
                    )
                    permissions.noteCaptureSuccess()
                    await deliverAll(captures)
                    hygiene?.endCapture()
                } catch {
                    hygiene?.endCapture()
                    handle(error)
                }
            }
        }
    }

    /// Captures one display with no overlay, the `display=` form of fullscreen.
    func captureDisplay(_ displayID: CGDirectDisplayID) {
        rememberBeautifySkip()
        if captureHeldFreeze(displayID: displayID) { return }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        inFlight?.cancel()
        let seconds = timerSeconds
        timer.run(seconds: seconds) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    await engine.setDynamicRange(settings.captureDynamicRange)
                    await hygiene?.beginCaptureAndSettle()
                    await CaptureExclusionPush.into(engine)
                    let capture = try await engine.captureDisplay(
                        displayID,
                        includesCursor: includesCursor
                    )
                    permissions.noteCaptureSuccess()
                    await deliver(capture)
                    hygiene?.endCapture()
                } catch {
                    hygiene?.endCapture()
                    handle(error)
                }
            }
        }
    }

    /// Freeze inspect is up: capture those pixels instead of photographing live UI
    /// (docs/03 §7).
    var isInspectingFreeze: Bool {
        purpose == .inspect && overlay.isPresented
    }

    /// Takes the frozen frames and delivers them as display captures.
    @discardableResult
    func captureHeldFreeze(displayID: CGDirectDisplayID? = nil) -> Bool {
        guard isInspectingFreeze else { return false }
        let held = takeHeldFreezes()
        let chosen = displayID.map { id in held.filter { $0.geometry.displayID == id } } ?? held
        deliverHeld(chosen)
        return true
    }

    /// Crops the last area out of the freeze, so "previous area" stays WYSIWYG.
    @discardableResult
    func captureHeldFreezeCroppingLastRegion() -> Bool {
        guard isInspectingFreeze, let lastRegion else { return false }
        guard let frozen = overlay.heldFreezes.first(where: {
            $0.geometry.displayID == lastRegion.displayID
        }) else {
            return captureHeldFreeze()
        }
        let local = frozen.geometry.localRect(for: lastRegion.rect)
        guard let image = frozen.croppedImage(localRect: local.cgRect) else { return false }
        _ = takeHeldFreezes()
        deliverHeldCrop(image, rect: lastRegion.rect, display: frozen.geometry)
        return true
    }

    func takeHeldFreezes() -> [FrozenDisplay] {
        let held = overlay.stealFreezesAndDismiss()
        hygiene?.endCapture()
        purpose = .capture
        return held
    }

    func deliverHeld(_ frozen: [FrozenDisplay]) {
        guard !frozen.isEmpty else { return }
        let captures = frozen.map { Self.capture(from: $0, frontmost: frontmostAtHotkey) }
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            if captures.count == 1, let only = captures.first {
                await deliver(only)
            } else {
                await deliverAll(captures)
            }
        }
    }

    func deliverHeldCrop(_ image: CGImage, rect: DisplayRect, display: DisplayGeometry) {
        let capture = Capture(
            image: image,
            metadata: CaptureMetadata(
                source: .region(display: display.displayID),
                displayID: display.displayID,
                scale: display.scale,
                pointRect: rect,
                pixelSize: PixelSize(width: image.width, height: image.height),
                colorSpaceName: image.colorSpace?.name as String?,
                frontmostApp: frontmostAtHotkey
            )
        )
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.deliver(capture)
        }
    }

    /// Frozen pixels as a still capture, without going back to ScreenCaptureKit.
    nonisolated static func capture(from frozen: FrozenDisplay, frontmost: AppIdentity?) -> Capture {
        Capture(
            image: frozen.image,
            metadata: CaptureMetadata(
                source: .display(frozen.geometry.displayID),
                displayID: frozen.geometry.displayID,
                scale: frozen.geometry.scale,
                pointRect: frozen.geometry.frame,
                pixelSize: PixelSize(width: frozen.image.width, height: frozen.image.height),
                colorSpaceName: frozen.image.colorSpace?.name as String?,
                frontmostApp: frontmost
            )
        )
    }
}
