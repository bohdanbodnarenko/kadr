import CoreGraphics
import Foundation

/// Everything the user decided about a recording (docs/09 U3.1, U3.4, U3.5).
///
/// One value, saved to `edit.json`, and the only input to a render besides the footage
/// itself. That is what the render stamp hashes, and what makes "has this changed" a
/// question with an exact answer rather than a guess.
public struct StudioEdit: Sendable, Hashable, Codable {
    /// Bumped when a field's meaning changes, as against a field being added.
    public static let currentVersion = 1

    public var version: Int
    /// Which pieces of the recording survive, and how fast they play.
    public var clips: ClipTimeline
    /// The zooms, in edited time.
    public var zooms: [ZoomCue]
    /// The shape the video comes out.
    public var reframe: Reframe
    /// Where the webcam sits.
    public var camera: CameraBubble
    /// Whether to draw the reconstructed cursor.
    ///
    /// On by default because the recording was made without one — turning it off leaves a
    /// video with no pointer at all, which is a deliberate choice rather than the absence
    /// of a decision.
    public var showsCursor: Bool
    /// Whether to draw ripples where the user clicked.
    public var showsClicks: Bool
    /// Whether to caption keyboard shortcuts.
    public var showsKeystrokes: Bool

    public init(
        version: Int = StudioEdit.currentVersion,
        clips: ClipTimeline = ClipTimeline(),
        zooms: [ZoomCue] = [],
        reframe: Reframe = .original,
        camera: CameraBubble = .standard,
        showsCursor: Bool = true,
        showsClicks: Bool = true,
        showsKeystrokes: Bool = true
    ) {
        self.version = version
        self.clips = clips
        self.zooms = zooms
        self.reframe = reframe
        self.camera = camera
        self.showsCursor = showsCursor
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
    }

    /// The edit a freshly-stopped recording starts with: everything, unchanged.
    public static func untouched(duration: TimeInterval) -> StudioEdit {
        StudioEdit(clips: .whole(duration: duration))
    }

    /// How long the finished video is.
    public var duration: TimeInterval {
        clips.editedDuration
    }

    /// The cues as they should be rendered, with the reframe's corrections applied.
    ///
    /// Computed rather than stored, so changing the aspect ratio re-plans the camera
    /// immediately instead of leaving cues that point off the new frame.
    public func renderableZooms(in size: CGSize) -> [ZoomCue] {
        reframe.replanning(zooms, in: size)
    }

    private enum CodingKeys: String, CodingKey {
        case version, clips, zooms, reframe, camera, showsCursor, showsClicks, showsKeystrokes
    }

    /// Every field defaults, so an edit written by a later Kadr still opens — it simply
    /// arrives without whatever was added (docs/08 §2.6).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            clips: container.decodeIfPresent(ClipTimeline.self, forKey: .clips) ?? ClipTimeline(),
            zooms: container.decodeIfPresent([ZoomCue].self, forKey: .zooms) ?? [],
            reframe: container.decodeIfPresent(Reframe.self, forKey: .reframe) ?? .original,
            camera: container.decodeIfPresent(CameraBubble.self, forKey: .camera) ?? .standard,
            showsCursor: container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true,
            showsClicks: container.decodeIfPresent(Bool.self, forKey: .showsClicks) ?? true,
            showsKeystrokes: container.decodeIfPresent(Bool.self, forKey: .showsKeystrokes) ?? true
        )
    }
}

/// A named studio look (docs/09 U3.5).
///
/// The same idea as the editor's style presets, and deliberately the same shape: a preset
/// carries the *presentation* decisions and leaves the content alone. Applying one must
/// never touch the clips — somebody trying a vertical layout has not asked to lose their
/// cuts, and a preset that could do that is a preset nobody dares try.
public struct StudioPreset: Sendable, Hashable, Codable, Identifiable {
    public static let currentVersion = 1

    public var id: UUID
    public var name: String
    public var version: Int
    public var reframe: Reframe
    public var camera: CameraBubble
    public var showsCursor: Bool
    public var showsClicks: Bool
    public var showsKeystrokes: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        version: Int = StudioPreset.currentVersion,
        reframe: Reframe = .original,
        camera: CameraBubble = .standard,
        showsCursor: Bool = true,
        showsClicks: Bool = true,
        showsKeystrokes: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.reframe = reframe
        self.camera = camera
        self.showsCursor = showsCursor
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
    }

    /// The look an edit is currently wearing.
    public init(name: String, capturing edit: StudioEdit) {
        self.init(
            name: name,
            reframe: edit.reframe,
            camera: edit.camera,
            showsCursor: edit.showsCursor,
            showsClicks: edit.showsClicks,
            showsKeystrokes: edit.showsKeystrokes
        )
    }

    /// Applies this look, leaving the clips and the zooms alone.
    public func applied(to edit: StudioEdit) -> StudioEdit {
        var updated = edit
        updated.reframe = reframe
        updated.camera = camera
        updated.showsCursor = showsCursor
        updated.showsClicks = showsClicks
        updated.showsKeystrokes = showsKeystrokes
        return updated
    }

    /// Whether an edit is wearing exactly this look.
    ///
    /// Identity is excluded, as in the editor's presets: applying a preset must not stop
    /// matching the instant it is applied (docs/09 U1.5).
    public func matches(_ edit: StudioEdit) -> Bool {
        StudioPreset(name: name, capturing: edit).appearance == appearance
    }

    /// Everything except the name and the identity.
    public var appearance: StudioPreset {
        var stripped = self
        stripped.id = Self.comparisonID
        stripped.name = ""
        stripped.version = Self.currentVersion
        return stripped
    }

    private static let comparisonID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    private enum CodingKeys: String, CodingKey {
        case id, name, version, reframe, camera, showsCursor, showsClicks, showsKeystrokes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled",
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            reframe: container.decodeIfPresent(Reframe.self, forKey: .reframe) ?? .original,
            camera: container.decodeIfPresent(CameraBubble.self, forKey: .camera) ?? .standard,
            showsCursor: container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true,
            showsClicks: container.decodeIfPresent(Bool.self, forKey: .showsClicks) ?? true,
            showsKeystrokes: container.decodeIfPresent(Bool.self, forKey: .showsKeystrokes) ?? true
        )
    }

    // MARK: - Built-ins

    public static let builtIn: [StudioPreset] = [
        StudioPreset(name: "As Recorded"),
        StudioPreset(
            name: "Widescreen",
            reframe: Reframe(aspect: .sixteenNine),
            camera: .standard
        ),
        StudioPreset(
            name: "Vertical",
            reframe: Reframe(aspect: .nineSixteen),
            camera: CameraBubble(placement: .bottom, sizeFraction: 0.3)
        ),
        StudioPreset(
            name: "Square",
            reframe: Reframe(aspect: .square),
            camera: .standard
        ),
        StudioPreset(
            name: "Clean",
            camera: CameraBubble(isVisible: false),
            showsClicks: false,
            showsKeystrokes: false
        )
    ]
}
