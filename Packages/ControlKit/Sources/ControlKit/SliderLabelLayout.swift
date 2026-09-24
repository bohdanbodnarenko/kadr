import AppKit
import Foundation

/// Where the title and the value sit so the handle never lands on top of them (docs/09 U1.5).
///
/// The handle is the same colour as the text, so where the two cross the letters melt into
/// the bar. Rather than draw one over the other, the label the handle reaches jumps to the
/// opposite end of the track and stays there, so a label is always at a fixed place and never
/// chases the handle:
///
/// - the **title** rests at the leading end and jumps to the trailing end, just before the
///   number, while the handle is in or near its resting place;
/// - the **number** rests at the trailing end and jumps to the leading end, just after the
///   title, while the handle is in or near its resting place.
///
/// Which end a label is at is a decision with hysteresis: it jumps when the handle gets within
/// `clearance` of it, and comes home only once the handle is `clearance + releaseMargin`
/// away, so a handle parked at the boundary does not make the label flutter between the two.
/// The view animates the jump; this only says where each label is meant to be. When both
/// ends are taken, on a track too short for the title and the number, the label stays at
/// whichever end the handle is farther from.
struct SliderLabelLayout: Equatable {
    struct Placement: Equatable {
        /// The title has jumped to the trailing end.
        var titleAtTrailing = false
        /// The value has jumped to the leading end.
        var valueAtLeading = false
    }

    let geometry: SliderGeometry
    let textInset: Double
    /// The title's text width, or 0 when there is no title.
    let titleWidth: Double
    /// The number's text width as drawn right now.
    let valueWidth: Double
    /// The fixed box the number, or the field it becomes, lives in. At least `valueWidth`.
    let valueBoxWidth: Double
    /// The widest the number ever gets, so a title beside it does not shift as the digits change.
    let valueReserve: Double
    /// The space kept between a label and the handle.
    var clearance: Double = 8
    /// Extra distance the handle must retreat before a label that jumped goes home.
    var releaseMargin: Double = 8
    /// Between the title and the number when they share an end.
    var labelGap: Double = 10

    /// The title is truncated rather than let run into the value's box.
    var titleShownWidth: Double {
        guard titleWidth > 0 else { return 0 }
        let room = geometry.width - textInset * 2 - valueBoxWidth - clearance
        return min(titleWidth + 2, max(room, 0))
    }

    // MARK: - Slots

    /// The title's leading edge.
    func titleX(_ placement: Placement) -> Double {
        guard placement.titleAtTrailing else { return textInset }
        let reserved = placement.valueAtLeading ? 0 : valueReserve + labelGap
        return geometry.width - textInset - reserved - titleShownWidth
    }

    /// The value box's trailing edge, which is also the number's.
    func valueRight(_ placement: Placement) -> Double {
        guard placement.valueAtLeading else { return geometry.width - textInset }
        let after = placement.titleAtTrailing || titleShownWidth == 0 ? 0 : titleShownWidth + labelGap
        return textInset + after + valueWidth
    }

    private func titleSpan(_ placement: Placement) -> ClosedRange<Double> {
        let left = titleX(placement)
        return left ... left + titleShownWidth
    }

    private func valueSpan(_ placement: Placement) -> ClosedRange<Double> {
        let right = valueRight(placement)
        return max(right - valueWidth, 0) ... right
    }

    /// The horizontal spans the labels occupy, for keeping other marks off them.
    func occupiedSpans(_ placement: Placement) -> [ClosedRange<Double>] {
        (titleShownWidth > 0 ? [titleSpan(placement)] : []) + [valueSpan(placement)]
    }

    /// Whether a press at `x` is on the number's box, where a click means "type".
    func isOnValue(x: Double, placement: Placement) -> Bool {
        let right = valueRight(placement)
        return x >= right - valueBoxWidth - 4 && x <= right + 4
    }

    // MARK: - Deciding

    /// Whether each label should have jumped, given where it was and where the handle is.
    func resolved(from previous: Placement, progress: Double) -> Placement {
        let center = geometry.handleCenter(progress: progress)
        let handle = (center - geometry.handleWidth / 2) ... (center + geometry.handleWidth / 2)
        var next = previous

        if titleShownWidth > 0 {
            next.titleAtTrailing = shouldJump(
                wasJumped: previous.titleAtTrailing,
                home: titleSpan(Placement(titleAtTrailing: false, valueAtLeading: previous.valueAtLeading)),
                away: titleSpan(Placement(titleAtTrailing: true, valueAtLeading: previous.valueAtLeading)),
                handle: handle
            )
        } else {
            next.titleAtTrailing = false
        }

        next.valueAtLeading = shouldJump(
            wasJumped: previous.valueAtLeading,
            home: valueSpan(Placement(titleAtTrailing: next.titleAtTrailing, valueAtLeading: false)),
            away: valueSpan(Placement(titleAtTrailing: next.titleAtTrailing, valueAtLeading: true)),
            handle: handle
        )
        return next
    }

    private func shouldJump(
        wasJumped: Bool,
        home: ClosedRange<Double>,
        away: ClosedRange<Double>,
        handle: ClosedRange<Double>
    ) -> Bool {
        let homeGap = gap(home, handle)
        // A label that has already jumped needs more room at home before it goes back.
        let homeNeeds = wasJumped ? clearance + releaseMargin : clearance
        if homeGap >= homeNeeds {
            return false
        }
        let awayGap = gap(away, handle)
        if awayGap >= clearance {
            return true
        }
        // Neither end is clear: stay with the one the handle is farther from.
        return awayGap > homeGap
    }

    /// The clear space between a span and the handle: negative when they overlap.
    private func gap(_ span: ClosedRange<Double>, _ handle: ClosedRange<Double>) -> Double {
        max(span.lowerBound - handle.upperBound, handle.lowerBound - span.upperBound)
    }
}

/// How wide a piece of slider text will be drawn, measured so layout can be decided before
/// SwiftUI has laid the text out.
enum SliderTextMetrics {
    static func width(of text: String, fontSize: Double, monospacedDigits: Bool = false) -> Double {
        let size = CGFloat(fontSize)
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
            : NSFont.systemFont(ofSize: size, weight: .medium)
        return ceil(Double((text as NSString).size(withAttributes: [.font: font]).width))
    }
}

/// The ghost marks along the track, revealed while the slider is engaged (docs/09 U1.5).
struct SliderTick: Equatable {
    let x: Double
    /// The mark for zero on a signed range: the detent, made one of the ticks.
    let isZero: Bool
}

enum SliderTicks {
    /// About how far apart ticks sit, in points.
    static let spacing: Double = 30

    /// Evenly spaced across the handle's travel; a signed range grows its grid outward from
    /// zero instead, so the detent is one of the marks rather than a stray line between them.
    static func ticks(in geometry: SliderGeometry, zeroProgress: Double?) -> [SliderTick] {
        let travel = geometry.handleTravel
        guard geometry.travelLength >= spacing else { return [] }

        guard let zeroProgress else {
            let segments = max(Int((geometry.travelLength / spacing).rounded()), 2)
            return (0 ... segments).map { index in
                let progress = Double(index) / Double(segments)
                return SliderTick(x: geometry.handleCenter(progress: progress), isZero: false)
            }
        }

        let zeroX = geometry.handleCenter(progress: zeroProgress)
        var xs: [Double] = []
        var step = 1.0
        while zeroX - step * spacing >= travel.lowerBound - 0.5 {
            xs.append(zeroX - step * spacing)
            step += 1
        }
        step = 1
        while zeroX + step * spacing <= travel.upperBound + 0.5 {
            xs.append(zeroX + step * spacing)
            step += 1
        }
        return (xs.map { SliderTick(x: $0, isZero: false) } + [SliderTick(x: zeroX, isZero: true)])
            .sorted { $0.x < $1.x }
    }

    /// How visible a tick is: not at all where it would sit on a label or under the handle.
    static func isClear(
        _ tick: SliderTick,
        of spans: [ClosedRange<Double>],
        handleX: Double,
        margin: Double = 5
    ) -> Bool {
        if abs(tick.x - handleX) < 9 {
            return false
        }
        return !spans.contains { tick.x >= $0.lowerBound - margin && tick.x <= $0.upperBound + margin }
    }
}
