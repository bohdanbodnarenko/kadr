import AppKit
import CaptureCore
import MediaExport
import os
import OverlayKit
import SelectionUI
import SettingsKit
import Shared

/// Drives a scrolling capture end to end (docs/03 §1.6, docs/04 §4.4).
///
/// Two tiers, one flow. The user sets a live frame over the page (`ScrollRegionEditor`), then
/// either scrolls the content themselves — which needs no permission at all and is the
/// default — or lets Kadr synthesize the scrolling, which needs Accessibility and asks for
/// it at that moment. Either way the frames go to disk and the stitch happens in the
/// helper, so the agent never holds a long page.
@MainActor
@Observable
final class ScrollCaptureCoordinator {
    enum State: Equatable {
        case idle
        /// Frames are being grabbed while the page scrolls.
        case capturing
        /// The helper is joining them up.
        case stitching
    }

    /// Internal so the frame editor (`+Stage`) can find the window under the pointer.
    @ObservationIgnored let captureEngine: CaptureEngine
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored private let output: CaptureOutput
    @ObservationIgnored private let vision = VisionClient()
    @ObservationIgnored private let session = ScrollCaptureSession()
    @ObservationIgnored let scroller = AutoScroller()
    /// Internal, not private: the seam-review half lives in
    /// `ScrollCaptureCoordinator+Seams.swift`, and `private` is file-scoped.
    @ObservationIgnored let logger = KadrLog.logger(.capture)
    @ObservationIgnored let recovery = PermissionRecovery()

    private(set) var state: State = .idle
    private(set) var frameCount = 0
    /// The running sketch of the page so far.
    private(set) var preview: CGImage?
    /// Set while Kadr is doing the scrolling itself. Written only by the auto tier
    /// (`ScrollCaptureCoordinator+Auto.swift`), which is another file, so not `private(set)`.
    var isAutoScrolling = false

    @ObservationIgnored private let strip = ScrollPreviewStrip()
    @ObservationIgnored private var hud: ScrollCaptureHUD?
    /// The picked area, dimmed around, waiting for Start (`ScrollCaptureCoordinator+Stage`).
    @ObservationIgnored var stage: ScrollRegionEditor?
    @ObservationIgnored var autoScrollTask: Task<Void, Never>?
    /// Bumped by every frame that lands, so the auto tier can tell a fresh frame from the
    /// one it already judged.
    @ObservationIgnored var frameSequence = 0
    @ObservationIgnored var lastRowProfile: RowProfile?
    @ObservationIgnored var lastColumnProfile: ColumnProfile?
    @ObservationIgnored private var sticky = StickyBands.none
    @ObservationIgnored private var stickyResolved = false
    @ObservationIgnored var region: (rect: DisplayRect, display: DisplayGeometry)?

    /// Where the finished page lands: the same Quick Access path as any other capture.
    var onFinished: ((URL, PixelSize) -> Void)?

    /// One-shot reporter for `kadr capture-scrolling` (docs/03 §8.4). Cleared when the
    /// capture ends, whichever way it ends.
    @ObservationIgnored private var automationCompletion: ((CaptureOutcome) -> Void)?

    /// Bumped whenever a capture begins or ends.
    ///
    /// A stitch runs in the helper and takes seconds; cancelling meanwhile used to leave
    /// it running, and its result then arrived as a finished page for a capture the user
    /// had abandoned. The stitch carries the token it started with and drops everything
    /// if it no longer matches (docs/07 M5).
    @ObservationIgnored private var sessionToken = 0
    @ObservationIgnored private var overrides: ScrollingOverrides = .none

    init(
        captureEngine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        output: CaptureOutput
    ) {
        self.captureEngine = captureEngine
        self.permissions = permissions
        self.settings = settings
        self.output = output
    }

    var isRunning: Bool {
        state != .idle
    }

    // MARK: - Starting

    /// Arms the next scrolling capture with a place to report its result.
    func arm(overrides: ScrollingOverrides = .none, completion: ((CaptureOutcome) -> Void)?) {
        report(.cancelled)
        self.overrides = overrides
        automationCompletion = completion
    }

    private func report(_ outcome: CaptureOutcome) {
        guard let automationCompletion else { return }
        self.automationCompletion = nil
        overrides = .none
        automationCompletion(outcome)
    }

    var usesAutoScroll: Bool {
        overrides.autoScroll ?? settings.scrollAutoScroll
    }

    /// Shows the adjustable frame over the live screen; Start begins grabbing frames.
    ///
    /// No freeze and no drawing: the frame opens around the window under the pointer, and
    /// the page stays live underneath so it can be scrolled into place first
    /// (`ScrollRegionEditor`).
    ///
    /// The command toggles: a second press while the frame is up cancels it, and while
    /// frames are being grabbed it is Stop (T-CAP-10).
    func begin() {
        if state == .capturing {
            stop()
            return
        }
        if stage != nil, state == .idle {
            dismissStage()
            finish(nil)
            return
        }
        guard state == .idle, stage == nil else { return }
        guard recovery.allowCapture(permissions: permissions, includePicker: false) else { return }
        guard let screen = ActiveScreen.resolve() else { return }
        Task { [weak self] in
            guard let self else { return }
            let window = await windowUnderPointer(on: screen)
            guard stage == nil, state == .idle else { return }
            presentEditor(on: screen, aroundWindow: window)
        }
    }

    /// Starts scrolling a named rectangle with no overlay (docs/03 §8.4 `display=`).
    func begin(region screenRect: ScreenRect) {
        guard state == .idle else { return }
        guard recovery.allowCapture(permissions: permissions, includePicker: false) else { return }
        let global = screenRect.inDisplaySpace(.current)
        guard let displayID = DisplayLookup.display(containing: global) else {
            report(.failed("That region is not on any display."))
            return
        }
        let geometry = DisplayGeometry(
            displayID: displayID,
            frame: DisplayRect(cgRect: CGDisplayBounds(displayID)),
            scale: NSScreen.screens.compactMap(ScreenDescriptor.init)
                .first { $0.displayID == displayID }?.scale ?? .oneToOne
        )
        start(region: global, display: geometry)
    }

    /// - Parameter auto: true when the user asked for the auto tier on the way in. The
    ///   setting is the standing preference; this is the button they just pressed.
    func start(region rect: DisplayRect, display: DisplayGeometry, auto: Bool = false) {
        sessionToken += 1
        region = (rect, display)
        lastRowProfile = nil
        lastColumnProfile = nil
        sticky = .none
        stickyResolved = false
        frameCount = 0
        preview = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                await CaptureExclusionPush.into(session)
                try await session.start(
                    region: rect,
                    on: display.displayID,
                    axis: settings.scrollAxis,
                    frameRate: settings.scrollFrameRate
                ) { [weak self] note in
                    Task { @MainActor in
                        self?.received(note)
                    }
                }
                await strip.begin(frameSize: session.pixelSize, axis: settings.scrollAxis)
                state = .capturing
                showHUD(over: rect, on: display)
                // Trust was settled before Start (`confirmAutoScrollTrust`), so an
                // untrusted run is simply the assisted tier — no prompt over live frames.
                if auto || usesAutoScroll, AutoScroller.isTrusted {
                    startAutoScroll(in: rect, on: display)
                }
                logger.info("Scrolling capture started")
            } catch {
                permissions.noteCaptureFailure(error)
                logger.error("Scrolling capture failed to start: \(error.localizedDescription, privacy: .public)")
                dismissStage()
                presentPermissionRecoveryIfNeeded(error)
                if !CaptureError.mapping(error).indicatesPermissionLoss {
                    FailurePresenter.present(message: "Kadr could not start the scrolling capture.")
                }
                report(.failed(error.localizedDescription))
            }
        }
    }

    private func presentPermissionRecoveryIfNeeded(_ error: any Error) {
        guard CaptureError.mapping(error).indicatesPermissionLoss else { return }
        switch recovery.present(state: permissions.state, includePicker: false) {
        case .openSettings:
            recovery.openSystemSettings()
        case .usePicker, .dismiss:
            break
        }
    }

    // MARK: - Frames

    /// One frame landed: extend the preview and, if Kadr is scrolling, decide whether the
    /// page has run out.
    private func received(_ note: ScrollCaptureSession.ScrollFrameNote) {
        frameCount = note.index + 1
        frameSequence += 1

        switch settings.scrollAxis {
        case .vertical:
            receivedVertical(note)
        case .horizontal:
            receivedHorizontal(note)
        }
    }

    private func receivedVertical(_ note: ScrollCaptureSession.ScrollFrameNote) {
        defer { lastRowProfile = note.rowProfile }
        guard let previous = lastRowProfile else {
            strip.append(
                frameAt: note.url,
                band: 0 ..< note.rowProfile.height,
                frameExtent: note.rowProfile.height
            )
            preview = strip.image
            return
        }

        var alignment = ScrollAligner.align(previous: previous, current: note.rowProfile, sticky: sticky)
        if !stickyResolved, alignment.offset > 0 {
            stickyResolved = true
            sticky = ScrollAligner.stickyBands(
                previous: previous,
                current: note.rowProfile,
                offset: alignment.offset
            )
            if sticky != .none {
                alignment = ScrollAligner.align(previous: previous, current: note.rowProfile, sticky: sticky)
            }
        }

        guard alignment.offset > 0 else { return }
        let bottom = note.rowProfile.height - sticky.footer
        strip.append(
            frameAt: note.url,
            band: max(0, bottom - alignment.offset) ..< bottom,
            frameExtent: note.rowProfile.height
        )
        preview = strip.image
    }

    private func receivedHorizontal(_ note: ScrollCaptureSession.ScrollFrameNote) {
        defer { lastColumnProfile = note.columnProfile }
        guard let previous = lastColumnProfile else {
            strip.append(
                frameAt: note.url,
                band: 0 ..< note.columnProfile.width,
                frameExtent: note.columnProfile.width
            )
            preview = strip.image
            return
        }

        var alignment = ColumnAligner.align(previous: previous, current: note.columnProfile, sticky: sticky)
        if !stickyResolved, alignment.offset > 0 {
            stickyResolved = true
            sticky = ColumnAligner.stickyBands(
                previous: previous,
                current: note.columnProfile,
                offset: alignment.offset
            )
            if sticky != .none {
                alignment = ColumnAligner.align(previous: previous, current: note.columnProfile, sticky: sticky)
            }
        }

        guard alignment.offset > 0 else { return }
        let trailing = note.columnProfile.width - sticky.footer
        strip.append(
            frameAt: note.url,
            band: max(0, trailing - alignment.offset) ..< trailing,
            frameExtent: note.columnProfile.width
        )
        preview = strip.image
    }

    // MARK: - Stopping

    /// Stops grabbing frames and asks the helper to join them up.
    func stop() {
        guard state == .capturing else { return }
        autoScrollTask?.cancel()
        autoScrollTask = nil
        isAutoScrolling = false
        state = .stitching
        hud?.showStitching()

        Task { [weak self] in
            guard let self else { return }
            let frames = await session.stop()
            if frames.count == 1, let only = frames.first {
                // Nothing scrolled: the one frame is still a capture, not a failure (T-CAP-6).
                await deliverSingleFrame(only)
                return
            }
            guard frames.count >= 2 else {
                logger.info("Scrolling capture ended with no frames")
                await session.discard()
                finish(nil)
                FailurePresenter.present(message: "The scrolling capture ended before any frame was taken.")
                return
            }
            await stitch(frames: frames, excluding: [])
        }
    }

    /// Throws the capture away without stitching anything.
    func cancel() {
        guard state != .idle else { return }
        autoScrollTask?.cancel()
        autoScrollTask = nil
        isAutoScrolling = false
        // Invalidates any stitch already in flight before it can report (docs/07 M5).
        sessionToken += 1
        Task { [weak self] in
            await self?.session.discard()
            self?.finish(nil)
        }
    }

    private func stitch(frames: [URL], excluding excluded: [Int]) async {
        // Everything below suspends, and a cancel can land in any of those gaps.
        let token = sessionToken
        let size = await session.pixelSize
        guard let destination = output.stagingURL(pixelSize: size) else {
            await session.discard()
            finish(nil)
            return
        }
        do {
            let response = try await vision.stitchScroll(ScrollStitchRequest(
                framePaths: frames.map(\.path),
                destinationPath: destination.path,
                excludedFrames: excluded,
                axis: settings.scrollAxis
            ))
            vision.disconnect()

            let url = URL(fileURLWithPath: response.path)
            guard token == sessionToken else {
                // Cancelled while the helper was working: throw the page away rather than
                // handing the user something they asked not to have (docs/07 M5).
                logger.info("Discarding a stitch for a cancelled capture")
                try? FileManager.default.removeItem(at: url)
                await session.discard()
                return
            }
            logger.info("Stitched \(response.pixelSize.height, privacy: .public) px of page")

            if settings.scrollReviewsSeams, !response.uncertainSeams.isEmpty {
                switch reviewSeams(response, frames: frames) {
                case .keep:
                    break
                case .retry:
                    // A retry drops the frames either side of the worst seam and joins
                    // what is left; a bad frame is usually one that landed mid-animation.
                    try? FileManager.default.removeItem(at: url)
                    let worst = response.uncertainSeams.min { $0.confidence < $1.confidence }
                    await stitch(frames: frames, excluding: worst.map { [$0.frameIndex] } ?? [])
                    return
                case .exportFrames:
                    try? FileManager.default.removeItem(at: url)
                    exportFrames(frames)
                    await session.discard()
                    finish(nil)
                    return
                }
            }

            await session.discard()
            finish(url, size: response.pixelSize)
        } catch {
            vision.disconnect()
            guard token == sessionToken else {
                await session.discard()
                return
            }
            logger.error("Stitching failed: \(error.localizedDescription, privacy: .public)")
            presentStitchFailure(frames: frames)
            await session.discard()
            finish(nil)
        }
    }

    func finish(_ url: URL?, size: PixelSize = PixelSize(width: 0, height: 0)) {
        sessionToken += 1
        dismissStage()
        hud?.dismiss()
        hud = nil
        strip.reset()
        preview = nil
        frameCount = 0
        region = nil
        state = .idle
        if let url {
            onFinished?(url, size)
            report(.file(url))
        } else {
            report(.cancelled)
        }
    }

    // MARK: - The HUD

    private func showHUD(over rect: DisplayRect, on display: DisplayGeometry) {
        let hud = ScrollCaptureHUD(
            coordinator: self,
            settings: settings,
            near: rect.inScreenSpace(GlobalCoordinateSpace.current)
        )
        hud.present()
        self.hud = hud
    }
}

/// The one-frame case, outside the class body to keep it within its length budget.
@MainActor
private extension ScrollCaptureCoordinator {
    /// A capture where the page never moved: its one frame is delivered as it is.
    func deliverSingleFrame(_ frame: URL) async {
        let token = sessionToken
        let size = await session.pixelSize
        guard let staged = output.stagingURL(pixelSize: size) else {
            await session.discard()
            finish(nil)
            return
        }
        // The frame is a PNG; keep the extension honest whatever the export format.
        let destination = staged.deletingPathExtension().appendingPathExtension("png")
        do {
            try FileManager.default.copyItem(at: frame, to: destination)
        } catch {
            logger.error("Could not keep the single frame: \(error.localizedDescription, privacy: .public)")
            await session.discard()
            finish(nil)
            FailurePresenter.present(message: "Kadr could not save the scrolling capture.")
            return
        }
        await session.discard()
        guard token == sessionToken else {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        logger.info("Scrolling capture had one frame; delivering it as an ordinary capture")
        finish(destination, size: size)
    }
}
