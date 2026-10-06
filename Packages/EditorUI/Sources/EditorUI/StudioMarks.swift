import Foundation

/// The in and out marks on the studio timeline (docs/18 T-STU-11).
///
/// Times are edited time, the finished video's clock, because that is what the user sees
/// under the playhead when they press I or O. Not part of the saved edit: marks say
/// "this stretch, for now", and an export of the whole thing should not need them cleared.
public struct StudioMarks: Equatable, Sendable {
    public var inPoint: TimeInterval?
    public var outPoint: TimeInterval?
    /// Whether Export renders only the marked range.
    public var exportsRangeOnly = false

    /// The shortest range worth exporting: one clip's minimum.
    public static let minimumLength: TimeInterval = 0.12

    public init(inPoint: TimeInterval? = nil, outPoint: TimeInterval? = nil, exportsRangeOnly: Bool = false) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.exportsRangeOnly = exportsRangeOnly
    }

    public var isEmpty: Bool {
        inPoint == nil && outPoint == nil
    }

    /// The marked stretch of an edit `duration` long. A missing mark stands for that end
    /// of the edit, so I alone exports from there to the end and O alone from the start.
    /// Nil when nothing is marked or the stretch is too short to export.
    public func range(duration: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard !isEmpty, duration > 0 else { return nil }
        let start = min(max(inPoint ?? 0, 0), duration)
        let end = min(max(outPoint ?? duration, 0), duration)
        guard end - start >= Self.minimumLength else { return nil }
        return start ... end
    }

    /// What Export should render alone, or nil for the whole edit.
    public func exportRange(duration: TimeInterval) -> ClosedRange<TimeInterval>? {
        exportsRangeOnly ? range(duration: duration) : nil
    }

    /// Sets the in mark, dropping an out mark it would cross.
    public mutating func markIn(at time: TimeInterval) {
        inPoint = time
        if let outPoint, outPoint <= time {
            self.outPoint = nil
        }
    }

    /// Sets the out mark, dropping an in mark it would cross.
    public mutating func markOut(at time: TimeInterval) {
        outPoint = time
        if let inPoint, inPoint >= time {
            self.inPoint = nil
        }
    }

    public mutating func clear() {
        self = StudioMarks()
    }
}

@MainActor
public extension StudioDocumentModel {
    /// I: marks the playhead as the start of the range.
    func markIn() {
        marks.markIn(at: playhead)
    }

    /// O: marks the playhead as the end of the range.
    func markOut() {
        marks.markOut(at: playhead)
    }

    /// ⌥X: clears both marks.
    func clearMarks() {
        marks.clear()
    }
}
