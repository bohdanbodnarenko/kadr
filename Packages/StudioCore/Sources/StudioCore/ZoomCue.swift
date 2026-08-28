import CoreGraphics
import Foundation

/// Where a zoom points (docs/09 U3.3).
public enum ZoomAnchor: Sendable, Hashable, Codable {
    /// A fixed point in the recorded area, in its own pixels.
    case fixed(CGPoint)
    /// The centre of the clicks that produced this cue.
    ///
    /// Stored as a point rather than recomputed, and that is deliberate: an anchor that
    /// followed the pointer would make the camera dither as the user moves during a zoom,
    /// which is the single most common way an automatic zoom looks cheap. The cluster's
    /// centre is decided once, from the clicks that justified the zoom, and does not move.
    case cluster(CGPoint)
    /// The middle of the frame.
    case centre

    /// Where this anchor is, given the recorded area.
    public func point(in size: CGSize) -> CGPoint {
        switch self {
        case let .fixed(point): point
        case let .cluster(point): point
        case .centre: CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }
}

/// One zoom, as a piece of editable data (docs/09 U3.3).
///
/// Data rather than a rendered effect. A cue can be moved, retimed, deleted and undone; a
/// baked zoom can only be re-rendered. It is also what makes the preview and the export
/// agree — both read the same cues and compute the same timeline, rather than one
/// approximating the other.
public struct ZoomCue: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// When the zoom begins, in *edited* time — after cuts and speed changes, because that
    /// is the timeline the viewer experiences.
    public var start: TimeInterval
    /// How long it stays zoomed, excluding the moves in and out.
    public var duration: TimeInterval
    /// How far in. 1 is no zoom at all.
    public var magnification: Double
    public var anchor: ZoomAnchor
    /// How long the camera takes to move in, and out again.
    public var transitionDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        duration: TimeInterval,
        magnification: Double = 1.8,
        anchor: ZoomAnchor = .centre,
        transitionDuration: TimeInterval = 0.6
    ) {
        self.id = id
        self.start = max(start, 0)
        self.duration = max(duration, 0)
        self.magnification = min(max(magnification, 1), Self.maximumMagnification)
        self.anchor = anchor
        self.transitionDuration = min(max(transitionDuration, 0.1), 2)
    }

    /// Past about four times, a 1080p recording is showing individual pixels.
    public static let maximumMagnification: Double = 4

    /// When the camera has finished moving out again.
    public var end: TimeInterval {
        start + duration + transitionDuration * 2
    }

    /// The range the zoom occupies, moves included.
    public var range: ClosedRange<TimeInterval> {
        start ... max(end, start)
    }

    public func overlaps(_ other: ZoomCue) -> Bool {
        range.overlaps(other.range)
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, duration, magnification, anchor, transitionDuration
    }

    /// Every field defaults, so a cue written by a later Kadr still opens (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            start: container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0,
            duration: container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
            magnification: container.decodeIfPresent(Double.self, forKey: .magnification) ?? 1.8,
            anchor: container.decodeIfPresent(ZoomAnchor.self, forKey: .anchor) ?? .centre,
            transitionDuration: container.decodeIfPresent(
                TimeInterval.self,
                forKey: .transitionDuration
            ) ?? 0.6
        )
    }
}

/// Proposes zooms from where the user clicked (docs/09 U3.3).
///
/// "Add smart zooms" is the feature that makes the studio worth opening for somebody who
/// will not hand-place cues, and clicks are the right signal: a burst of clicks in one part
/// of the screen is somebody doing something there, which is the thing worth showing
/// closely.
///
/// Pure, so the suggestions are reviewable rather than magical — the same recording always
/// produces the same cues, and a test can state exactly what "a cluster" means.
public struct ZoomCuePlanner: Sendable {
    /// Clicks closer together than this in time belong to the same activity.
    public var maximumGap: TimeInterval
    /// Clicks further apart than this on screen are separate activities, however close in
    /// time — as a fraction of the recorded area's shortest edge.
    public var maximumSpreadFraction: Double
    /// A cluster of fewer clicks than this is somebody passing through rather than working.
    public var minimumClicks: Int
    /// How long a proposed zoom holds after its last click, so the viewer sees the result
    /// of what was clicked rather than cutting away at the moment of impact.
    public var tail: TimeInterval

    public init(
        maximumGap: TimeInterval = 2.5,
        maximumSpreadFraction: Double = 0.25,
        minimumClicks: Int = 2,
        tail: TimeInterval = 1.2
    ) {
        self.maximumGap = max(maximumGap, 0.1)
        self.maximumSpreadFraction = max(maximumSpreadFraction, 0.01)
        self.minimumClicks = max(minimumClicks, 1)
        self.tail = max(tail, 0)
    }

    /// Zooms for a recording.
    ///
    /// - Parameters:
    ///   - clicks: the presses, in recording time.
    ///   - size: the recorded area, for judging what "close together" means on screen.
    ///   - duration: the recording's length, so nothing is proposed past the end.
    public func cues(for clicks: [ClickEvent], in size: CGSize, duration: TimeInterval) -> [ZoomCue] {
        let presses = clicks.filter(\.isDown).sorted { $0.time < $1.time }
        guard !presses.isEmpty, duration > 0 else { return [] }

        let spread = max(min(size.width, size.height), 1) * maximumSpreadFraction
        return clusters(of: presses, spread: spread).compactMap { cluster in
            guard cluster.count >= minimumClicks else { return nil }
            return cue(for: cluster, duration: duration)
        }
    }

    /// Groups presses that are close in both time and place.
    ///
    /// Both, not either. Two clicks a second apart at opposite corners are two activities,
    /// and zooming to the midpoint of them would frame neither.
    private func clusters(of presses: [ClickEvent], spread: CGFloat) -> [[ClickEvent]] {
        var clusters: [[ClickEvent]] = []
        var current: [ClickEvent] = []

        for press in presses {
            guard let last = current.last else {
                current = [press]
                continue
            }
            let gap = press.time - last.time
            let distance = hypot(press.position.x - last.position.x, press.position.y - last.position.y)
            if gap <= maximumGap, distance <= spread {
                current.append(press)
            } else {
                clusters.append(current)
                current = [press]
            }
        }
        if !current.isEmpty {
            clusters.append(current)
        }
        return clusters
    }

    private func cue(for cluster: [ClickEvent], duration: TimeInterval) -> ZoomCue? {
        guard let first = cluster.first, let last = cluster.last else { return nil }

        // The centre is fixed here and never recomputed: an anchor that followed the
        // pointer would make the camera dither during the zoom.
        let centre = CGPoint(
            x: cluster.reduce(0) { $0 + $1.position.x } / CGFloat(cluster.count),
            y: cluster.reduce(0) { $0 + $1.position.y } / CGFloat(cluster.count)
        )

        // A little before the first click, so the camera has arrived by the time anything
        // happens — arriving *as* it happens means the viewer sees the movement rather
        // than the click.
        let transition: TimeInterval = 0.6
        let start = max(first.time - transition, 0)
        let hold = max(last.time - first.time + tail, 0.5)
        guard start < duration else { return nil }

        return ZoomCue(
            start: start,
            duration: min(hold, duration - start),
            magnification: 1.8,
            anchor: .cluster(centre),
            transitionDuration: transition
        )
    }
}
