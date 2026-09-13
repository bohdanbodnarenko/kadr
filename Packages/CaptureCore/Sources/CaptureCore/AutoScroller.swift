import ApplicationServices
import CoreGraphics
import Foundation
import os
import Shared

/// The auto tier of scrolling capture: Kadr does the scrolling (docs/03 §1.6, docs/04 §4.4).
///
/// Synthesizing scroll wheel events needs Accessibility, which is a serious permission and
/// the reason this is a second tier rather than the only one — the assisted tier works
/// with nothing but Screen Recording, and stays the default. The permission is asked for
/// the first time someone actually turns auto-scroll on, never at launch (docs/04 §3.2).
public struct AutoScroller: Sendable {
    private let logger = KadrLog.logger(.capture)

    public struct Configuration: Sendable, Hashable {
        /// Points per step. Smaller means more overlap between frames and a safer stitch;
        /// larger finishes sooner.
        public var pointsPerStep: Int
        /// How long to let the page settle after each step, in milliseconds. Momentum
        /// scrolling and lazily-loaded content both need a moment before the next frame
        /// means anything.
        public var settleMilliseconds: Int
        /// A stop, so a page that never settles cannot scroll forever.
        public var maximumSteps: Int

        public init(pointsPerStep: Int = 120, settleMilliseconds: Int = 320, maximumSteps: Int = 400) {
            self.pointsPerStep = pointsPerStep
            self.settleMilliseconds = settleMilliseconds
            self.maximumSteps = maximumSteps
        }
    }

    public init() {}

    /// Whether synthesized events would actually be delivered.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for Accessibility, showing the system prompt.
    ///
    /// Returns whether the grant is already in place; a fresh grant only takes effect for
    /// the *next* attempt, because macOS does not hand it over mid-launch. The caller says
    /// so rather than silently doing nothing.
    @discardableResult
    public static func requestTrust() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    /// Sends one vertical scroll step to whatever is under `point`.
    ///
    /// Pixel units rather than lines: a line is whatever the target app decides it is, and
    /// the stitch wants a predictable, modest step with plenty of overlap.
    public func step(at point: CGPoint, configuration: Configuration = Configuration()) {
        postScroll(at: point, wheel1: Int32(-configuration.pointsPerStep), wheel2: 0)
    }

    /// Sends one horizontal scroll step to whatever is under `point`.
    public func stepHorizontally(at point: CGPoint, configuration: Configuration = Configuration()) {
        postScroll(at: point, wheel1: 0, wheel2: Int32(-configuration.pointsPerStep))
    }

    private func postScroll(at point: CGPoint, wheel1: Int32, wheel2: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else {
            logger.error("Could not synthesize a scroll event")
            return
        }
        // Positioning the event is what aims it: it lands on whatever window is under the
        // point, with no need to find or activate that window ourselves.
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

/// Decides when a scrolled page has stopped changing (docs/04 §4.4).
///
/// Frame differencing rather than a fixed delay: a fast local page settles in one frame
/// and a lazily-loading one takes several, and waiting the worst case every time would
/// make auto-scroll unusably slow. Two consecutive frames that did not move mean the page
/// has run out — either it has been scrolled to the end, or the target ignores us.
public struct ScrollSettleDetector: Sendable {
    /// Frames with no movement before the page counts as finished.
    public let requiredStillFrames: Int
    public let axis: ScrollAxis
    private var stillFrames = 0
    private var previousVertical: RowProfile?
    private var previousHorizontal: ColumnProfile?

    public init(requiredStillFrames: Int = 2, axis: ScrollAxis = .vertical) {
        self.requiredStillFrames = requiredStillFrames
        self.axis = axis
    }

    /// Whether the page has settled, given the newest frame.
    public mutating func settled(with profile: RowProfile) -> Bool {
        guard axis == .vertical else { return false }
        defer { previousVertical = profile }
        guard let previousVertical else { return false }

        let alignment = ScrollAligner.align(previous: previousVertical, current: profile)
        return recordMovement(alignment.offset == 0)
    }

    /// Whether the page has settled, given the newest frame.
    public mutating func settled(with profile: ColumnProfile) -> Bool {
        guard axis == .horizontal else { return false }
        defer { previousHorizontal = profile }
        guard let previousHorizontal else { return false }

        let alignment = ColumnAligner.align(previous: previousHorizontal, current: profile)
        return recordMovement(alignment.offset == 0)
    }

    private mutating func recordMovement(_ still: Bool) -> Bool {
        if still {
            stillFrames += 1
        } else {
            stillFrames = 0
        }
        return stillFrames >= requiredStillFrames
    }

    /// Forgets what it has seen, for a new run.
    public mutating func reset() {
        stillFrames = 0
        previousVertical = nil
        previousHorizontal = nil
    }
}
