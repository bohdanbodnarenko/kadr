import Foundation

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
    public var highlightsSpokenWord: Bool
    public var keystrokePlacement: OverlayPlacement
    public var captionPlacement: OverlayPlacement
    public var keystrokeScale: Double
    public var captionScale: Double
    public var cursorScale: Double
    public var clickScale: Double
    public var clickColor: StudioColor
    public var clickStyle: ClickRippleStyle
    public var showsClickPress: Bool
    public var cursorSmoothing: CursorSmoothing
    public var zoomStyle: ZoomAnimationStyle
    public var motionBlur: Double
    public var canvas: StudioCanvas

    public init(
        id: UUID = UUID(),
        name: String,
        version: Int = StudioPreset.currentVersion,
        reframe: Reframe = .original,
        camera: CameraBubble = .standard,
        showsCursor: Bool = true,
        showsClicks: Bool = true,
        showsKeystrokes: Bool = true,
        highlightsSpokenWord: Bool = true,
        keystrokePlacement: OverlayPlacement = .bottom,
        captionPlacement: OverlayPlacement = .top,
        keystrokeScale: Double = 1,
        captionScale: Double = 1,
        cursorScale: Double = 1,
        clickScale: Double = 1,
        clickColor: StudioColor = .white,
        clickStyle: ClickRippleStyle = .outline,
        showsClickPress: Bool = true,
        cursorSmoothing: CursorSmoothing = .smooth,
        zoomStyle: ZoomAnimationStyle = .smooth,
        motionBlur: Double = 0.5,
        canvas: StudioCanvas = .identity
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.reframe = reframe
        self.camera = camera
        self.showsCursor = showsCursor
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
        self.highlightsSpokenWord = highlightsSpokenWord
        self.keystrokePlacement = keystrokePlacement
        self.captionPlacement = captionPlacement
        self.keystrokeScale = StudioEdit.clampedOverlayScale(keystrokeScale)
        self.captionScale = StudioEdit.clampedOverlayScale(captionScale)
        self.cursorScale = StudioEdit.clampedCursorScale(cursorScale)
        self.clickScale = StudioEdit.clampedCursorScale(clickScale)
        self.clickColor = clickColor
        self.clickStyle = clickStyle
        self.showsClickPress = showsClickPress
        self.cursorSmoothing = cursorSmoothing
        self.zoomStyle = zoomStyle
        self.motionBlur = StudioEdit.clampedMotionBlur(motionBlur)
        self.canvas = canvas
    }

    /// The look an edit is currently wearing.
    ///
    /// Wallpaper files live in the session folder, so a saved look keeps the kind and
    /// drops the file name — applying it to another recording must not point at a path
    /// that recording does not have.
    public init(name: String, capturing edit: StudioEdit) {
        var canvas = edit.canvas
        canvas.wallpaperFileName = nil
        self.init(
            name: name,
            reframe: edit.reframe,
            camera: edit.camera,
            showsCursor: edit.showsCursor,
            showsClicks: edit.showsClicks,
            showsKeystrokes: edit.showsKeystrokes,
            highlightsSpokenWord: edit.highlightsSpokenWord,
            keystrokePlacement: edit.keystrokePlacement,
            captionPlacement: edit.captionPlacement,
            keystrokeScale: edit.keystrokeScale,
            captionScale: edit.captionScale,
            cursorScale: edit.cursorScale,
            clickScale: edit.clickScale,
            clickColor: edit.clickColor,
            clickStyle: edit.clickStyle,
            showsClickPress: edit.showsClickPress,
            cursorSmoothing: edit.cursorSmoothing,
            zoomStyle: edit.zoomStyle,
            motionBlur: edit.motionBlur,
            canvas: canvas
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
        updated.highlightsSpokenWord = highlightsSpokenWord
        updated.keystrokePlacement = keystrokePlacement
        updated.captionPlacement = captionPlacement
        updated.keystrokeScale = keystrokeScale
        updated.captionScale = captionScale
        updated.cursorScale = cursorScale
        updated.clickScale = clickScale
        updated.clickColor = clickColor
        updated.clickStyle = clickStyle
        updated.showsClickPress = showsClickPress
        updated.cursorSmoothing = cursorSmoothing
        updated.zoomStyle = zoomStyle
        updated.motionBlur = motionBlur
        let wallpaper = edit.canvas.wallpaperFileName
        updated.canvas = canvas
        if case .wallpaper = canvas.background {
            updated.canvas.wallpaperFileName = wallpaper
        }
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
        case id, name, version, reframe, camera, showsCursor, showsClicks, showsKeystrokes,
             highlightsSpokenWord, keystrokePlacement, captionPlacement, keystrokeScale, captionScale,
             cursorScale, clickScale, clickColor, clickStyle, showsClickPress, cursorSmoothing,
             zoomStyle, motionBlur, canvas
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
            showsKeystrokes: container.decodeIfPresent(Bool.self, forKey: .showsKeystrokes) ?? true,
            highlightsSpokenWord: container.decodeIfPresent(Bool.self, forKey: .highlightsSpokenWord) ?? true,
            keystrokePlacement: container.decodeIfPresent(
                OverlayPlacement.self,
                forKey: .keystrokePlacement
            ) ?? .bottom,
            captionPlacement: container.decodeIfPresent(
                OverlayPlacement.self,
                forKey: .captionPlacement
            ) ?? .top,
            keystrokeScale: container.decodeIfPresent(Double.self, forKey: .keystrokeScale) ?? 1,
            captionScale: container.decodeIfPresent(Double.self, forKey: .captionScale) ?? 1,
            cursorScale: container.decodeIfPresent(Double.self, forKey: .cursorScale) ?? 1,
            clickScale: container.decodeIfPresent(Double.self, forKey: .clickScale) ?? 1,
            clickColor: container.decodeIfPresent(StudioColor.self, forKey: .clickColor) ?? .white,
            clickStyle: container.decodeIfPresent(ClickRippleStyle.self, forKey: .clickStyle) ?? .outline,
            showsClickPress: container.decodeIfPresent(Bool.self, forKey: .showsClickPress) ?? true,
            cursorSmoothing: container.decodeIfPresent(CursorSmoothing.self, forKey: .cursorSmoothing)
                ?? .smooth,
            zoomStyle: container.decodeIfPresent(ZoomAnimationStyle.self, forKey: .zoomStyle) ?? .smooth,
            motionBlur: container.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0.5,
            canvas: container.decodeIfPresent(StudioCanvas.self, forKey: .canvas) ?? .identity
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
        ),
        StudioPreset(
            name: "Presenter",
            canvas: .presenter
        ),
        StudioPreset(
            name: "Paper",
            canvas: .paper
        )
    ]

    /// The look a recording nobody has styled yet opens with.
    public static var presenter: StudioPreset {
        builtIn.first { $0.name == "Presenter" } ?? StudioPreset(name: "Presenter", canvas: .presenter)
    }
}
