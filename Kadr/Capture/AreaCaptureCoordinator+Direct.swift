import AppKit
import CaptureCore
import MediaExport
import os
import OverlayKit
import SelectionUI
import SettingsKit
import Shared

/// Direct (no overlay) capture paths used by automation and the fullscreen hotkey
/// (docs/03 §1.3, §8.4, CleanShot §20).
@MainActor
extension AreaCaptureCoordinator {
    /// Captures every display with no overlay at all (docs/03 §1.3).
    ///
    /// - Parameter frontmost: the app the user was in, when the caller sampled it before
    ///   Kadr took activation (the island does); nil samples it now (docs/17 T-CAP-3).
    func captureAllDisplays(frontmost: AppIdentity? = nil) {
        captureFullscreen(frontmost: frontmost)
    }

    /// Honours Settings → Capture → Fullscreen captures (docs/16 CAP-3).
    ///
    /// - Parameter target: this capture's target; nil follows the setting. The island's
    ///   Screen menu passes one so a single capture never rewrites Settings (T-CAP-5).
    func captureFullscreen(target: FullscreenTarget? = nil, frontmost: AppIdentity? = nil) {
        // Sampled here: nothing on this path set it, so a full-screen capture was named
        // after whatever app the previous capture saw (docs/17 T-CAP-3).
        frontmostAtHotkey = frontmost ?? Self.currentFrontmostApp()
        switch target ?? settings.fullscreenTarget {
        case .activeDisplay:
            if let displayID = ActiveScreen.resolve().flatMap({ ScreenDescriptor($0) })?.displayID {
                captureDisplay(displayID, frontmost: frontmostAtHotkey)
            } else {
                captureEveryDisplay(preferringActive: false)
            }
        case .allDisplays:
            captureEveryDisplay(preferringActive: true)
        case .allDisplaysStitched:
            captureStitchedDisplays()
        }
    }

    /// Captures every display with no overlay at all (docs/03 §1.3).
    func captureEveryDisplay(preferringActive: Bool) {
        rememberBeautifySkip()
        if captureHeldFreeze() {
            return
        }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        inFlight?.cancel()
        let seconds = timerSeconds
        // Every display is the target, so the badge goes where the user is looking.
        timer.run(seconds: seconds, screen: nil, displayID: nil) { [weak self] in
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
                    await deliverAll(Self.ordered(captures, preferringActive: preferringActive))
                    hygiene?.endCapture()
                } catch {
                    hygiene?.endCapture()
                    handle(error)
                }
            }
        }
    }

    /// Captures one display with no overlay, the `display=` form of fullscreen.
    func captureDisplay(_ displayID: CGDirectDisplayID, frontmost: AppIdentity? = nil) {
        rememberBeautifySkip()
        frontmostAtHotkey = frontmost ?? Self.currentFrontmostApp()
        if captureHeldFreeze(displayID: displayID) {
            return
        }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        inFlight?.cancel()
        let seconds = timerSeconds
        timer.run(seconds: seconds, displayID: displayID) { [weak self] in
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

    func captureStitchedDisplays() {
        rememberBeautifySkip()
        if captureHeldFreeze() {
            return
        }
        guard recovery.allowCapture(permissions: permissions, onPicker: { [weak self] in
            self?.captureWithSystemPicker()
        }) else { return }
        inFlight?.cancel()
        let seconds = timerSeconds
        timer.run(seconds: seconds, screen: nil, displayID: nil) { [weak self] in
            guard let self else { return }
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    await engine.setDynamicRange(settings.captureDynamicRange)
                    await hygiene?.beginCaptureAndSettle()
                    await CaptureExclusionPush.into(engine)
                    let captures = try await engine.captureAllDisplays(
                        includesCursor: includesCursor
                    )
                    permissions.noteCaptureSuccess()
                    if let stitched = Self.stitched(captures, frontmost: frontmostAtHotkey) {
                        await deliver(stitched)
                    } else if captures.count == 1, let only = captures.first {
                        await deliver(only)
                    } else {
                        await deliverAll(captures)
                    }
                    hygiene?.endCapture()
                } catch {
                    hygiene?.endCapture()
                    handle(error)
                }
            }
        }
    }

    static func ordered(_ captures: [Capture], preferringActive: Bool) -> [Capture] {
        guard preferringActive,
              let activeID = ActiveScreen.resolve().flatMap({ ScreenDescriptor($0) })?.displayID
        else {
            return captures
        }
        return captures.sorted { lhs, rhs in
            let left = lhs.metadata.displayID == activeID ? 0 : 1
            let right = rhs.metadata.displayID == activeID ? 0 : 1
            return left < right
        }
    }

    static func stitched(_ captures: [Capture], frontmost: AppIdentity?) -> Capture? {
        guard captures.count >= 2 else { return captures.first }
        let tiles = captures.map {
            DisplayStitcher.Tile(rect: $0.metadata.pointRect.cgRect, scale: $0.metadata.scale.factor)
        }
        guard let image = DisplayStitcher.compose(captures.map(\.image), tiles: tiles) else {
            return nil
        }
        let canvas = DisplayStitcher.canvas(for: tiles)
        return Capture(
            image: image,
            metadata: CaptureMetadata(
                source: .display(captures[0].metadata.displayID ?? 0),
                displayID: ActiveScreen.resolve().flatMap { ScreenDescriptor($0) }?.displayID
                    ?? captures[0].metadata.displayID,
                scale: DisplayScale(canvas.scale),
                pointRect: DisplayRect(cgRect: CGRect(origin: canvas.origin, size: CGSize(
                    width: canvas.size.width / canvas.scale,
                    height: canvas.size.height / canvas.scale
                ))),
                pixelSize: PixelSize(width: image.width, height: image.height),
                colorSpaceName: image.colorSpace?.name as String?,
                frontmostApp: frontmost
            )
        )
    }

    func captureRegionLive(_ rect: DisplayRect, on displayID: CGDirectDisplayID) {
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                // Before the pixels, not after (docs/07 H3).
                await hygiene?.beginCaptureAndSettle()
                await CaptureExclusionPush.into(engine)
                let capture = try await engine.captureRegion(
                    rect,
                    on: displayID,
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
