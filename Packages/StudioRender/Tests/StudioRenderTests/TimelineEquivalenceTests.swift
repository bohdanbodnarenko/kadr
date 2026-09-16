import CoreGraphics
import Foundation
import StudioSession
import Testing
@testable import StudioRender

/// The single-pass cursor path and viewport timeline against the searches they replaced.
///
/// Both precomputations were rewritten for speed and neither was allowed to change its
/// answer: the preview and every export already made agree with the old numbers, and a
/// "faster" timeline that moves the camera by a hair is a timeline that makes a re-export
/// differ from the file somebody already sent. So the old algorithms live on here, verbatim,
/// and the new ones must match them to the bit.
@Suite("Timeline equivalence")
struct TimelineEquivalenceTests {
    // MARK: - The algorithms as they were

    /// `CursorReconstruction.path(for:duration:)` before the single pass.
    static func referencePath(for telemetry: InputTelemetry, duration: TimeInterval) -> [CGPoint] {
        let targets = telemetry.pointer.map { (time: $0.time, value: $0.position) }
        guard !targets.isEmpty else { return [] }
        let presses = telemetry.clicks.filter(\.isDown).sorted { $0.time < $1.time }
        var x = DampedSpring(position: Double(targets[0].value.x), omega: DampedSpring.omega(settlingIn: 0.22))
        var y = DampedSpring(position: Double(targets[0].value.y), omega: x.omega)
        var result: [CGPoint] = []
        var time: TimeInterval = 0
        var index = 0
        while time <= duration {
            while index + 1 < targets.count, targets[index + 1].time <= time {
                index += 1
            }
            var aim = targets[index].value
            var omega = DampedSpring.omega(settlingIn: 0.22)
            if let last = telemetry.clicks.last(where: { $0.time <= time }), last.isDown {
                aim = targets[index].value
                omega = DampedSpring.omega(settlingIn: 0.08)
            } else if let press = presses.first(where: {
                $0.time >= time && $0.time - time <= CursorReconstruction.anticipation
            }) {
                aim = press.position
                if press.time - time <= CursorReconstruction.interceptWindow {
                    omega = DampedSpring.omega(settlingIn: 0.08)
                }
            }
            x.omega = omega
            y.omega = omega
            x.advance(towards: Double(aim.x), by: MotionSpring.step)
            y.advance(towards: Double(aim.y), by: MotionSpring.step)
            result.append(CGPoint(x: x.position, y: y.position))
            time += MotionSpring.step
        }
        return result
    }

    /// `ViewportTimeline.init` before the lookups were built once.
    static func referenceViewports(
        cues: [ZoomCue],
        size: CGSize,
        duration: TimeInterval,
        spring: MotionSpring = MotionSpring(),
        pointer: [PointerSample] = [],
        clips: ClipTimeline = ClipTimeline()
    ) -> (magnifications: [Double], centres: [CGPoint]) {
        let duration = max(duration, 0)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let steps = max(Int(duration / MotionSpring.step) + 1, 1)
        let ordered = cues.sorted { $0.start < $1.start }
        let pointer = pointer.sorted { $0.time < $1.time }
        var magnifications: [Double] = []
        var centres: [CGPoint] = []
        var magSpring = DampedSpring(
            position: 1,
            omega: DampedSpring.omega(settlingIn: max(ordered.first?.transitionDuration ?? 0.6, 0.1))
        )
        var xSpring = DampedSpring(position: centre.x, omega: magSpring.omega)
        var ySpring = DampedSpring(position: centre.y, omega: magSpring.omega)
        for step in 0 ..< steps {
            let time = Double(step) * MotionSpring.step
            let source = (clips.clips.isEmpty ? time : clips.sourceTime(forEdited: time)) ?? time
            let target = ViewportTimeline.target(
                times: (source: source, edited: time),
                cues: ordered,
                size: size,
                centre: centre,
                pointer: pointer
            )
            let transition = ordered.last { $0.range.contains(source) }?.transitionDuration ?? 0.6
            let omega = DampedSpring.omega(settlingIn: transition) * (spring.stiffness / 12)
            magSpring.omega = omega
            xSpring.omega = omega
            ySpring.omega = omega
            magSpring.advance(towards: target.magnification, by: MotionSpring.step)
            xSpring.advance(towards: target.centre.x, by: MotionSpring.step)
            ySpring.advance(towards: target.centre.y, by: MotionSpring.step)
            magnifications.append(magSpring.position)
            centres.append(CGPoint(x: xSpring.position, y: ySpring.position))
        }
        return (magnifications, centres)
    }

    // MARK: - Fixtures

    /// A deterministic generator, so a failing case can be reproduced from its seed.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    static func pointer(duration: TimeInterval, rate: Double = 60) -> [PointerSample] {
        stride(from: 0.0, through: duration, by: 1 / rate).map { time in
            PointerSample(time: time, position: CGPoint(x: 100 + time * 37, y: 200 + sin(time * 3) * 80))
        }
    }

    static func press(_ time: TimeInterval, _ x: CGFloat = 500, _ y: CGFloat = 300) -> ClickEvent {
        ClickEvent(time: time, position: CGPoint(x: x, y: y))
    }

    static func release(_ time: TimeInterval) -> ClickEvent {
        ClickEvent(time: time, position: CGPoint(x: 500, y: 300), isDown: false)
    }

    /// Named click layouts, each aimed at one way the single pass could go wrong.
    static let clickCases: [(name: String, clicks: [ClickEvent])] = [
        ("no clicks", []),
        ("one press and release", [press(1), release(1.1)]),
        ("a long drag", [press(0.5, 10, 10), release(2.5)]),
        ("a press that is never released", [press(1.2)]),
        ("releases only", [release(0.4), release(1.6)]),
        ("clustered presses", (0 ..< 12).flatMap { [press(1 + Double($0) * 0.03), release(1.01 + Double($0) * 0.03)] }),
        ("presses on the step grid", [
            press(MotionSpring.step * 60),
            release(MotionSpring.step * 61),
            press(MotionSpring.step * 120),
            release(MotionSpring.step * 180)
        ]),
        ("equal times, press last", [release(1), press(1)]),
        ("equal times, release last", [press(1), release(1)]),
        ("out of order", [release(2.2), press(0.8), press(2), release(0.9), press(0.1)]),
        ("drag inside a cluster", [press(1), press(1.05), release(1.5), press(1.52), release(1.53)]),
        ("before zero and past the end", [press(-1), release(-0.5), press(3.5)])
    ]

    // MARK: - Cursor path

    @Test("The cursor path matches the searching version exactly", arguments: clickCases.indices)
    func cursorPathMatches(caseIndex: Int) {
        let (name, clicks) = Self.clickCases[caseIndex]
        let telemetry = InputTelemetry(pointer: Self.pointer(duration: 3), clicks: clicks)
        let fast = CursorReconstruction().path(for: telemetry, duration: 3)
        let reference = Self.referencePath(for: telemetry, duration: 3)
        #expect(fast == reference, "\(name) diverged")
    }

    @Test("The cursor path matches on random telemetry", arguments: 0 ..< 24)
    func cursorPathMatchesRandom(seed: Int) {
        var random = SplitMix(state: UInt64(seed))
        let duration = Double.random(in: 1 ... 6, using: &random)
        let count = Int.random(in: 0 ... 80, using: &random)
        var clicks = (0 ..< count).map { _ in
            ClickEvent(
                // Coarse times on purpose, so equal and grid-aligned times turn up.
                time: (Double.random(in: -0.5 ... duration + 0.5, using: &random) * 20).rounded() / 20,
                position: CGPoint(
                    x: .random(in: 0 ... 1000, using: &random),
                    y: .random(in: 0 ... 1000, using: &random)
                ),
                isDown: Bool.random(using: &random)
            )
        }
        if seed.isMultiple(of: 2) {
            clicks.sort { $0.time < $1.time }
        }
        let telemetry = InputTelemetry(pointer: Self.pointer(duration: duration, rate: 30), clicks: clicks)
        let fast = CursorReconstruction().path(for: telemetry, duration: duration)
        let reference = Self.referencePath(for: telemetry, duration: duration)
        #expect(fast == reference, "seed \(seed) diverged")
    }

    /// PRD §8 / CLAUDE.md rule 9: the budget is a test, not a comment.
    ///
    /// Ten minutes with two thousand clicks is 72,000 steps; the search-per-step version
    /// made that some three hundred million comparisons. A single pass does it in tens of
    /// milliseconds even in a debug build. The bound is generous so a loaded CI machine
    /// passes, and still far below what the quadratic version took.
    @Test("A ten-minute path with two thousand clicks builds inside its budget")
    func cursorPathBudget() {
        let duration: TimeInterval = 600
        let clicks = (0 ..< 1000).flatMap { index -> [ClickEvent] in
            let time = Double(index) * 0.6
            return [Self.press(time), Self.release(time + 0.08)]
        }
        let telemetry = InputTelemetry(pointer: Self.pointer(duration: duration, rate: 30), clicks: clicks)
        let start = ContinuousClock.now
        let path = CursorReconstruction().path(for: telemetry, duration: duration)
        let elapsed = ContinuousClock.now - start
        #expect(path.count >= Int(duration / MotionSpring.step))
        #expect(elapsed < .seconds(1), "building the path took \(elapsed)")
    }

    // MARK: - Viewport timeline

    static let size = CGSize(width: 1920, height: 1080)

    static let cueCases: [(name: String, cues: [ZoomCue])] = [
        ("no cues", []),
        (
            "one fixed cue",
            [ZoomCue(start: 0.5, duration: 1, magnification: 2, anchor: .fixed(CGPoint(x: 300, y: 200)))]
        ),
        ("overlapping cues", [
            ZoomCue(start: 0.2, duration: 2, magnification: 1.5, transitionDuration: 0.3),
            ZoomCue(
                start: 1,
                duration: 0.5,
                magnification: 3,
                anchor: .fixed(CGPoint(x: 1500, y: 900)),
                transitionDuration: 1.2
            )
        ]),
        ("cues sharing boundaries", [
            ZoomCue(start: 0.5, duration: 0.3, magnification: 2, transitionDuration: 0.1),
            ZoomCue(start: 1, duration: 0.5, magnification: 2.5, transitionDuration: 0.2),
            ZoomCue(start: 0.5, duration: 0.3, magnification: 1.4, transitionDuration: 0.1)
        ]),
        ("pointer follow", [
            ZoomCue(start: 0.3, duration: 2, magnification: 2.2, anchor: .pointer, boundsBias: 0.4)
        ]),
        ("edges on the step grid", (0 ..< 16).map { index in
            ZoomCue(
                start: Double(index) / 4,
                duration: 1.0 / 24,
                magnification: 1 + Double(index % 3),
                transitionDuration: 0.1 + Double(index % 2) / 10
            )
        }),
        ("given out of order", [
            ZoomCue(start: 2, duration: 0.5, magnification: 2),
            ZoomCue(start: 0, duration: 0.4, magnification: 3, anchor: .cluster(CGPoint(x: 10, y: 10))),
            ZoomCue(start: 1, duration: 3, magnification: 1.2, transitionDuration: 2)
        ])
    ]

    static let clipCases: [(name: String, clips: ClipTimeline)] = [
        ("no clips", ClipTimeline()),
        ("whole", .whole(duration: 4)),
        ("a cut", ClipTimeline(clips: [
            Clip(sourceStart: 0, sourceDuration: 1.1),
            Clip(sourceStart: 2.3, sourceDuration: 1.7)
        ])),
        ("speed and reordering", ClipTimeline(clips: [
            Clip(sourceStart: 1, sourceDuration: 1, speed: 2),
            Clip(sourceStart: 0, sourceDuration: 0.7),
            Clip(sourceStart: 3, sourceDuration: 1.9, speed: 1.5)
        ])),
        ("many filler cuts", ClipTimeline(clips: (0 ..< 200).map { index in
            Clip(sourceStart: Double(index) * 0.03, sourceDuration: 0.02 + Double(index % 3) * 0.001)
        })),
        ("ends early", ClipTimeline(clips: [Clip(sourceStart: 0.5, sourceDuration: 1)])),
        // Every cut exactly on the 120 Hz grid, so steps land on the cuts themselves.
        ("cuts on the step grid", ClipTimeline(clips: (0 ..< 48).map { index in
            Clip(sourceStart: Double(index) / 12, sourceDuration: 1.0 / 12, speed: index.isMultiple(of: 5) ? 2 : 1)
        })),
        ("many sped-up clips, ending before the edit", ClipTimeline(clips: (0 ..< 60).map { index in
            Clip(sourceStart: Double(index) * 0.1, sourceDuration: 0.1, speed: 1 + Double(index % 4))
        }))
    ]

    @Test(
        "The viewport timeline matches the searching version exactly",
        arguments: cueCases.indices, clipCases.indices
    )
    func viewportsMatch(cueIndex: Int, clipIndex: Int) {
        let (cueName, cues) = Self.cueCases[cueIndex]
        let (clipName, clips) = Self.clipCases[clipIndex]
        let pointer = Self.pointer(duration: 4, rate: 20)
        let spring = MotionSpring(stiffness: 17)
        let timeline = ViewportTimeline(
            cues: cues,
            size: Self.size,
            duration: 4,
            spring: spring,
            pointer: pointer,
            clips: clips
        )
        let reference = Self.referenceViewports(
            cues: cues,
            size: Self.size,
            duration: 4,
            spring: spring,
            pointer: pointer,
            clips: clips
        )
        #expect(timeline.magnifications == reference.magnifications, "\(cueName) over \(clipName)")
        #expect(timeline.centres == reference.centres, "\(cueName) over \(clipName)")
    }

    /// PRD §8 / CLAUDE.md rule 9. Ten minutes after a filler-word pass — hundreds of clips —
    /// with a busy zoom track. Walking every clip on every step took well over a second of
    /// this in a debug build; the forward walk takes a small fraction of the bound.
    @Test("A ten-minute timeline with many clips and cues builds inside its budget")
    func viewportBudget() {
        let clips = ClipTimeline(clips: (0 ..< 400).map { index in
            Clip(sourceStart: Double(index) * 1.6, sourceDuration: 1.5)
        })
        let cues = (0 ..< 120).map { index in
            ZoomCue(start: Double(index) * 5, duration: 2, magnification: 2, anchor: .pointer)
        }
        let start = ContinuousClock.now
        let timeline = ViewportTimeline(
            cues: cues,
            size: Self.size,
            duration: clips.editedDuration,
            pointer: Self.pointer(duration: 640, rate: 10),
            clips: clips
        )
        let elapsed = ContinuousClock.now - start
        #expect(timeline.magnifications.count > 70000)
        #expect(elapsed < .milliseconds(500), "building the timeline took \(elapsed)")
    }

    @Test("The flattened clip walk agrees with the timeline everywhere", arguments: clipCases.indices)
    func clipWalkMatches(clipIndex: Int) {
        let clips = Self.clipCases[clipIndex].clips
        let walk = EditedToSource(clips)
        for step in -3 ..< 700 {
            let time = Double(step) * MotionSpring.step
            let expected = clips.clips.isEmpty ? time : clips.sourceTime(forEdited: time)
            #expect(walk.sourceTime(forEdited: time) == expected, "at \(time)")
        }
    }

    @Test("The quick source time is always within its stated tolerance", arguments: clipCases.indices)
    func estimateIsBounded(clipIndex: Int) {
        let clips = Self.clipCases[clipIndex].clips
        let walk = EditedToSource(clips)
        var cursor = walk.makeCursor()
        var decided = 0
        for step in -3 ..< 700 {
            let time = Double(step) * MotionSpring.step
            let exact = walk.sourceTime(forEdited: time) ?? time
            guard let estimate = walk.estimate(forEdited: time, cursor: &cursor) else { continue }
            decided += 1
            #expect(abs(estimate.source - exact) <= estimate.tolerance, "at \(time)")
            #expect(estimate.tolerance < 1e-9, "a tolerance of \(estimate.tolerance) decides nothing")
        }
        #expect(decided > 600, "the estimate gave up on \(703 - decided) steps")
    }

    @Test("The cue lookup finds the last containing cue at, between and beyond boundaries")
    func cueLookupMatches() {
        var random = SplitMix(state: 7)
        let cues = (0 ..< 30).map { _ in
            ZoomCue(
                start: (Double.random(in: 0 ... 10, using: &random) * 4).rounded() / 4,
                duration: (Double.random(in: 0 ... 2, using: &random) * 4).rounded() / 4,
                transitionDuration: (Double.random(in: 0.1 ... 1, using: &random) * 4).rounded() / 4
            )
        }
        let lookup = CueLookup(cues)
        let boundaries = cues.flatMap { [$0.range.lowerBound, $0.range.upperBound] }
        let probes = boundaries + boundaries.map(\.nextUp) + boundaries.map(\.nextDown)
            + stride(from: -1.0, through: 16, by: 0.01).map(\.self) + [.nan, .infinity, -.infinity]
        for time in probes {
            let expected = cues.lastIndex { $0.range.contains(time) }
            #expect(lookup.last(containing: time) == expected, "at \(time)")
            #expect(lookup.last(containing: time, within: 0) == .some(expected), "at \(time)")

            // With a tolerance, an answer is only given if it holds across the whole span.
            let tolerance = 1e-9
            if case let .some(answer) = lookup.last(containing: time, within: tolerance) {
                for nearby in [time - tolerance, time.nextDown, time, time.nextUp, time + tolerance] {
                    #expect(answer == cues.lastIndex { $0.range.contains(nearby) }, "near \(time)")
                }
            } else {
                #expect(boundaries.contains { abs($0 - time) <= tolerance }, "gave up far from any edge at \(time)")
            }
        }
    }
}
