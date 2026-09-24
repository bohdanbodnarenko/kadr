import Foundation

/// Where everything sits on a slider of a given size (docs/09 U1.5).
///
/// The fill is an inset pill that stops short of a floating handle, with a gap between
/// them. That gap is the whole look, so it has to be arithmetic rather than something
/// each view rediscovers: at zero the fill collapses to a circle as tall as it is wide,
/// and at full the handle sits just inside the trailing edge with the fill still a gap behind.
///
/// The handle, not the fill, is what the pointer drags, so the pointer's x is mapped over
/// the handle's travel and the handle stays under the cursor all the way to both ends.
struct SliderGeometry: Equatable {
    let width: Double
    let height: Double
    /// Space between the track's edge and the fill, so the fill reads as a pill inside one.
    var inset: Double
    var handleWidth: Double = 3
    /// Between the fill's trailing edge and the handle.
    var gap: Double = 6
    /// Between the handle at full and the track's inset, so it does not sit on the border.
    var trailingMargin: Double = 3

    /// The inset each control size draws with: a thinner border on a smaller pill.
    static func inset(forHeight height: Double) -> Double {
        height >= 28 ? 3 : 2
    }

    init(width: Double, height: Double) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        inset = Self.inset(forHeight: height)
    }

    var fillHeight: Double {
        max(height - inset * 2, 0)
    }

    /// Where the handle's centre can be: from the fill as a circle to the trailing inset.
    var handleTravel: ClosedRange<Double> {
        let lower = inset + fillHeight + gap + handleWidth / 2
        let upper = width - inset - trailingMargin - handleWidth / 2
        return lower ... max(lower, upper)
    }

    func handleCenter(progress: Double) -> Double {
        let travel = handleTravel
        let clamped = min(max(progress, 0), 1)
        return travel.lowerBound + clamped * (travel.upperBound - travel.lowerBound)
    }

    /// The fill's width: from the leading inset to a gap short of the handle.
    func fillWidth(progress: Double) -> Double {
        max(handleCenter(progress: progress) - handleWidth / 2 - gap - inset, fillHeight)
    }

    /// A pointer's x as a distance along the handle's travel, for `SliderMapping`.
    func travelledX(for locationX: Double) -> Double {
        locationX - handleTravel.lowerBound
    }

    var travelLength: Double {
        handleTravel.upperBound - handleTravel.lowerBound
    }
}
