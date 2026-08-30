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
/// Two tiers, one flow. The user picks a region with the overlay they already know, then
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

    @ObservationIgnored private let captureEngine: CaptureEngine
    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let overlay: SelectionOverlayController
    @ObservationIgnored private let output: CaptureOutput
    @ObservationIgnored private let vision = VisionClient()
    @ObservationIgnored private let session = ScrollCaptureSession()
    @ObservationIgnored private let scroller = AutoScroller()
    /// Internal, not private: the seam-review half lives in
    /// `ScrollCaptureCoordinator+Seams.swift`, and `private` is file-scoped.
    @ObservationIgnored let logger = KadrLog.logger(.capture)

    private(set) var state: State = .idle
    private(set) var frameCount = 0
    /// The running sketch of the page so far.
    private(set) var preview: CGImage?
    /// Set while Kadr is doing the scrolling itself.
    private(set) var isAutoScrolling = false

    @ObservationIgnored private let strip = ScrollPreviewStrip()
    @ObservationIgnored private var hud: ScrollCaptureHUD?
    @ObservationIgnored private var autoScrollTask: Task<Void, Never>?
    @ObservationIgnored private var lastProfile: RowProfile?
    @ObservationIgnored private var sticky = StickyBands.none
    @ObservationIgnored private var stickyResolved = false
    @ObservationIgnored private var region: (rect: DisplayRect, display: DisplayGeometry)?

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

    init(
        captureEngine: CaptureEngine,
        permissions: PermissionCoordinator,
        settings: AppSettings,
        output: CaptureOutput,
        overlay: SelectionOverlayController = SelectionOverlayController()
    ) {
        self.captureEngine = captureEngine
        self.permissions = permissions
        self.settings = settings
        self.output = output
        self.overlay = overlay
    }

    var isRunning: Bool {
        state != .idle
    }

    // MARK: - Starting

    /// Arms the next scrolling capture with a place to report its result.
    func arm(completion: ((CaptureOutcome) -> Void)?) {
        report(.cancelled)
        automationCompletion = completion
    }

    private func report(_ outcome: CaptureOutcome) {
        guard let automationCompletion else { return }
        self.automationCompletion = nil
        automationCompletion(outcome)
    }

    /// Picks the region to scroll through, then starts grabbing frames.
    func begin() {
        guard state == .idle else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                await CaptureExclusionPush.into(captureEngine)
                let freezes = try await captureEngine.freezeAllDisplays()
                permissions.noteCaptureSuccess()
                overlay.present(
                    freezes: freezes.map { FrozenDisplay(geometry: $0.geometry, image: $0.image) },
                    purpose: .scrollingCapture
                ) { [weak self] outcome in
                    guard case let .region(result) = outcome else {
                        self?.report(.cancelled)
                        return
                    }
                    self?.start(region: result.rect, display: result.display)
                }
            } catch {
                permissions.noteCaptureFailure(error)
                logger
                    .error("Could not freeze for a scrolling capture: \(error.localizedDescription, privacy: .public)")
                report(.failed(error.localizedDescription))
            }
        }
    }

    private func start(region rect: DisplayRect, display: DisplayGeometry) {
        sessionToken += 1
        region = (rect, display)
        lastProfile = nil
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
                    frameRate: settings.scrollFrameRate
                ) { note in
                    Task { @MainActor [weak self] in
                        self?.received(note)
                    }
                }
                await strip.begin(frameSize: session.pixelSize)
                state = .capturing
                showHUD(over: rect, on: display)
                if settings.scrollAutoScroll {
                    startAutoScroll(in: rect, on: display)
                }
                logger.info("Scrolling capture started")
            } catch {
                permissions.noteCaptureFailure(error)
                logger.error("Scrolling capture failed to start: \(error.localizedDescription, privacy: .public)")
                report(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Frames

    /// One frame landed: extend the preview and, if Kadr is scrolling, decide whether the
    /// page has run out.
    private func received(_ note: ScrollCaptureSession.ScrollFrameNote) {
        frameCount = note.index + 1

        defer { lastProfile = note.profile }
        guard let previous = lastProfile else {
            // The first frame is the whole of what is on screen.
            strip.append(frameAt: note.url, band: 0 ..< note.profile.height, frameHeight: note.profile.height)
            preview = strip.image
            return
        }

        var alignment = ScrollAligner.align(previous: previous, current: note.profile, sticky: sticky)
        if !stickyResolved, alignment.offset > 0 {
            stickyResolved = true
            sticky = ScrollAligner.stickyBands(
                previous: previous,
                current: note.profile,
                offset: alignment.offset
            )
            if sticky != .none {
                alignment = ScrollAligner.align(previous: previous, current: note.profile, sticky: sticky)
            }
        }

        guard alignment.offset > 0 else { return }
        let bottom = note.profile.height - sticky.footer
        strip.append(
            frameAt: note.url,
            band: max(0, bottom - alignment.offset) ..< bottom,
            frameHeight: note.profile.height
        )
        preview = strip.image
    }

    // MARK: - The auto tier

    /// Scrolls the target itself, stopping when the page stops changing (docs/04 §4.4).
    private func startAutoScroll(in rect: DisplayRect, on display: DisplayGeometry) {
        guard AutoScroller.isTrusted else {
            // Asking now rather than at launch is the whole policy (docs/04 §3.2). The
            // grant only takes effect next time, so this run stays assisted.
            AutoScroller.requestTrust()
            explainAccessibility()
            return
        }

        isAutoScrolling = true
        let centre = centrePoint(of: rect, on: display)
        let configuration = AutoScroller.Configuration(pointsPerStep: settings.scrollStepPoints)

        autoScrollTask = Task { [weak self] in
            guard let self else { return }
            var detector = ScrollSettleDetector()
            for _ in 0 ..< configuration.maximumSteps {
                if Task.isCancelled {
                    return
                }
                scroller.step(at: centre, configuration: configuration)
                try? await Task.sleep(for: .milliseconds(configuration.settleMilliseconds))
                if Task.isCancelled {
                    return
                }
                guard let profile = lastProfile else { continue }
                if detector.settled(with: profile) {
                    logger.info("Auto-scroll settled; the page has run out")
                    break
                }
            }
            isAutoScrolling = false
            stop()
        }
    }

    /// The middle of the captured region, in screen points, which is where a synthesized
    /// scroll has to land to reach the right window.
    private func centrePoint(of rect: DisplayRect, on display: DisplayGeometry) -> CGPoint {
        let screenRect = rect.inScreenSpace(GlobalCoordinateSpace.current)
        // CGEvent locations are in display space, top-left origin, which is what the rect
        // already is — the round trip is here only to make the space explicit.
        _ = screenRect
        return CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + rect.height / 2)
    }

    private func explainAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Kadr needs Accessibility to scroll for you"
        alert.informativeText = "Auto-scroll works by sending scroll events to the window "
            + "you picked, which macOS only allows with Accessibility permission. Grant it "
            + "in System Settings and try again — this capture will carry on with you doing "
            + "the scrolling."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
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
            guard frames.count >= 2 else {
                logger.info("Scrolling capture ended with too few frames to stitch")
                await session.discard()
                finish(nil)
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
                excludedFrames: excluded
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

    private func finish(_ url: URL?, size: PixelSize = PixelSize(width: 0, height: 0)) {
        sessionToken += 1
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
            near: rect.inScreenSpace(GlobalCoordinateSpace.current)
        )
        hud.present()
        self.hud = hud
    }
}
