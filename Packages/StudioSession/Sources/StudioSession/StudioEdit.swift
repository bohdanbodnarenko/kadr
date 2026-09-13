import CoreGraphics
import Foundation
import Shared

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
    /// Optional free crop in normalised 0…1 source space, applied before the aspect reframe
    /// (docs/10 R3.5). Nil means the whole frame.
    public var cropRect: CGRect?
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
    /// Burned-in captions from the transcript (docs/13 T2.2).
    public var showsCaptions: Bool
    /// Colour the word being said, when captions are on (docs/13 T2.2).
    public var highlightsSpokenWord: Bool
    /// Where shortcut captions sit on the recording card.
    public var keystrokePlacement: OverlayPlacement
    /// Where burned-in speech captions sit on the recording card.
    public var captionPlacement: OverlayPlacement
    /// Dark or light caption pill (CleanShot §13.5).
    public var keystrokeAppearance: OverlayChromeAppearance
    /// How large shortcut captions are drawn, 1 being the default size.
    public var keystrokeScale: Double {
        didSet {
            let next = Self.clampedOverlayScale(keystrokeScale)
            if next != keystrokeScale {
                keystrokeScale = next
            }
        }
    }

    /// How large burned-in speech captions are drawn, 1 being the default size.
    public var captionScale: Double {
        didSet {
            let next = Self.clampedOverlayScale(captionScale)
            if next != captionScale {
                captionScale = next
            }
        }
    }

    /// File name, inside the session folder, of a soundtrack imported to replace the
    /// recording's own audio. Nil means use the clips' audio as captured.
    public var soundtrackFileName: String?
    /// The imported file's name as the user chose it, for the inspector.
    public var soundtrackDisplayName: String?
    /// Drop audio from preview and export (CleanShot §13.3 / §14.8).
    public var mutesAudio: Bool
    /// Mix stereo down to one channel on export (CleanShot §13.3 / §14.8).
    public var mixesToMono: Bool
    /// How large the reconstructed pointer is drawn, 1 being the recorded size.
    public var cursorScale: Double {
        didSet {
            let next = Self.clampedCursorScale(cursorScale)
            if next != cursorScale {
                cursorScale = next
            }
        }
    }

    /// How large click ripples are drawn, 1 being the default size.
    public var clickScale: Double {
        didSet {
            let next = Self.clampedCursorScale(clickScale)
            if next != clickScale {
                clickScale = next
            }
        }
    }

    /// Colour of the click ripple. White is the live overlay; a brand colour is a look.
    public var clickColor: StudioColor
    /// Outline ring or a filled disc (CleanShot §14.4).
    public var clickStyle: ClickRippleStyle
    /// Scale the pointer down at the instant of a click (CleanShot §14.4).
    public var showsClickPress: Bool
    /// How aggressively the reconstructed pointer is cleaned up (CleanShot §14.4).
    public var cursorSmoothing: CursorSmoothing
    /// How the camera eases into a zoom, independent of the pointer (CleanShot §14.3).
    public var zoomStyle: ZoomAnimationStyle
    /// How hard moving zooms smear, 0…1. Zero is a slideshow; one is cinematic.
    public var motionBlur: Double {
        didSet {
            let next = Self.clampedMotionBlur(motionBlur)
            if next != motionBlur {
                motionBlur = next
            }
        }
    }

    /// Padding, corners and backdrop around the recording.
    public var canvas: StudioCanvas
    /// Whether any zoom runs. Off leaves the cues on the lane so they can be turned back on.
    public var showsZooms: Bool

    public init(
        version: Int = StudioEdit.currentVersion,
        clips: ClipTimeline = ClipTimeline(),
        zooms: [ZoomCue] = [],
        reframe: Reframe = .original,
        cropRect: CGRect? = nil,
        camera: CameraBubble = .standard,
        showsCursor: Bool = true,
        showsClicks: Bool = true,
        showsKeystrokes: Bool = true,
        showsCaptions: Bool = false,
        highlightsSpokenWord: Bool = true,
        keystrokePlacement: OverlayPlacement = .bottom,
        captionPlacement: OverlayPlacement = .top,
        keystrokeAppearance: OverlayChromeAppearance = .dark,
        keystrokeScale: Double = 1,
        captionScale: Double = 1,
        soundtrackFileName: String? = nil,
        soundtrackDisplayName: String? = nil,
        mutesAudio: Bool = false,
        mixesToMono: Bool = false,
        cursorScale: Double = 1,
        clickScale: Double = 1,
        clickColor: StudioColor = .white,
        clickStyle: ClickRippleStyle = .outline,
        showsClickPress: Bool = true,
        cursorSmoothing: CursorSmoothing = .smooth,
        zoomStyle: ZoomAnimationStyle = .smooth,
        motionBlur: Double = 0.5,
        canvas: StudioCanvas = .identity,
        showsZooms: Bool = true
    ) {
        self.version = version
        self.clips = clips
        self.zooms = zooms
        self.reframe = reframe
        self.cropRect = cropRect
        self.camera = camera
        self.showsCursor = showsCursor
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
        self.showsCaptions = showsCaptions
        self.highlightsSpokenWord = highlightsSpokenWord
        self.keystrokePlacement = keystrokePlacement
        self.captionPlacement = captionPlacement
        self.keystrokeAppearance = keystrokeAppearance
        self.keystrokeScale = Self.clampedOverlayScale(keystrokeScale)
        self.captionScale = Self.clampedOverlayScale(captionScale)
        self.soundtrackFileName = soundtrackFileName
        self.soundtrackDisplayName = soundtrackDisplayName
        self.mutesAudio = mutesAudio
        self.mixesToMono = mixesToMono
        self.cursorScale = Self.clampedCursorScale(cursorScale)
        self.clickScale = Self.clampedCursorScale(clickScale)
        self.clickColor = clickColor
        self.clickStyle = clickStyle
        self.showsClickPress = showsClickPress
        self.cursorSmoothing = cursorSmoothing
        self.zoomStyle = zoomStyle
        self.motionBlur = Self.clampedMotionBlur(motionBlur)
        self.canvas = canvas
        self.showsZooms = showsZooms
    }

    public static let minimumCursorScale: Double = 0.5
    public static let maximumCursorScale: Double = 4
    public static let minimumOverlayScale: Double = 0.6
    public static let maximumOverlayScale: Double = 1.8

    static func clampedCursorScale(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 1, minimumCursorScale), maximumCursorScale)
    }

    static func clampedOverlayScale(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 1, minimumOverlayScale), maximumOverlayScale)
    }

    static func clampedMotionBlur(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0.5, 0), 1)
    }

    /// The edit a freshly-stopped recording starts with: everything, unchanged.
    public static func untouched(duration: TimeInterval) -> StudioEdit {
        StudioEdit(clips: .whole(duration: duration))
    }

    /// How long the finished video is.
    public var duration: TimeInterval {
        clips.editedDuration
    }

    /// The cues as they should be rendered, with the combined crop applied.
    ///
    /// Computed rather than stored, so changing the aspect ratio or the free crop re-plans
    /// the camera immediately instead of leaving cues that point off the new frame.
    public func renderableZooms(in size: CGSize) -> [ZoomCue] {
        guard showsZooms else { return [] }
        let active = zooms.filter(\.isEnabled)
        let crop = sourceRect(for: size)
        guard crop.width > 0, crop.height > 0 else { return active }
        let identity = crop.origin == .zero
            && abs(crop.width - size.width) < 0.5
            && abs(crop.height - size.height) < 0.5
        guard !identity else { return active }

        let inherentZoom = size.width / crop.width
        return active.map { cue in
            var replanned = cue
            replanned.magnification = max(cue.magnification / inherentZoom, 1)
            if cue.anchor.followsPointer {
                return replanned
            }
            let anchor = cue.anchor.point(in: size)
            let pulled = CGPoint(
                x: min(max(anchor.x, crop.minX), crop.maxX),
                y: min(max(anchor.y, crop.minY), crop.maxY)
            )
            replanned.anchor = .fixed(pulled)
            return replanned
        }
    }

    /// The part of the recording that survives the free crop and then the aspect reframe,
    /// in source pixels.
    public func sourceRect(for size: CGSize) -> CGRect {
        let free = pixelCrop(in: size)
        let inner = reframe.sourceRect(for: free.size)
        return inner.offsetBy(dx: free.minX, dy: free.minY)
    }

    /// The exported frame's pixel size after the free crop and the aspect reframe.
    public func outputSize(for size: CGSize) -> CGSize {
        reframe.outputSize(for: pixelCrop(in: size).size)
    }

    /// The free crop as a pixel rect, or the whole frame when there is none.
    public func pixelCrop(in size: CGSize) -> CGRect {
        guard let cropRect else { return CGRect(origin: .zero, size: size) }
        let x = min(max(cropRect.origin.x, 0), 1)
        let y = min(max(cropRect.origin.y, 0), 1)
        let width = min(max(cropRect.width, 0), 1 - x)
        let height = min(max(cropRect.height, 0), 1 - y)
        guard width > 0, height > 0 else { return CGRect(origin: .zero, size: size) }
        return CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version, clips, zooms, reframe, cropRect, camera, showsCursor, showsClicks, showsKeystrokes,
             showsCaptions, highlightsSpokenWord, keystrokePlacement, captionPlacement, keystrokeAppearance,
             keystrokeScale, captionScale,
             soundtrackFileName, soundtrackDisplayName, mutesAudio, mixesToMono,
             cursorScale, clickScale, clickColor, clickStyle,
             showsClickPress, cursorSmoothing, zoomStyle, motionBlur, canvas, showsZooms
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
            cropRect: container.decodeIfPresent(CGRect.self, forKey: .cropRect),
            camera: container.decodeIfPresent(CameraBubble.self, forKey: .camera) ?? .standard,
            showsCursor: container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true,
            showsClicks: container.decodeIfPresent(Bool.self, forKey: .showsClicks) ?? true,
            showsKeystrokes: container.decodeIfPresent(Bool.self, forKey: .showsKeystrokes) ?? true,
            showsCaptions: container.decodeIfPresent(Bool.self, forKey: .showsCaptions) ?? false,
            highlightsSpokenWord: container.decodeIfPresent(Bool.self, forKey: .highlightsSpokenWord) ?? true,
            keystrokePlacement: container.decodeIfPresent(
                OverlayPlacement.self,
                forKey: .keystrokePlacement
            ) ?? .bottom,
            captionPlacement: container.decodeIfPresent(
                OverlayPlacement.self,
                forKey: .captionPlacement
            ) ?? .top,
            keystrokeAppearance: container.decodeIfPresent(
                OverlayChromeAppearance.self,
                forKey: .keystrokeAppearance
            ) ?? .dark,
            keystrokeScale: container.decodeIfPresent(Double.self, forKey: .keystrokeScale) ?? 1,
            captionScale: container.decodeIfPresent(Double.self, forKey: .captionScale) ?? 1,
            soundtrackFileName: container.decodeIfPresent(String.self, forKey: .soundtrackFileName),
            soundtrackDisplayName: container.decodeIfPresent(String.self, forKey: .soundtrackDisplayName),
            mutesAudio: container.decodeIfPresent(Bool.self, forKey: .mutesAudio) ?? false,
            mixesToMono: container.decodeIfPresent(Bool.self, forKey: .mixesToMono) ?? false,
            cursorScale: container.decodeIfPresent(Double.self, forKey: .cursorScale) ?? 1,
            clickScale: container.decodeIfPresent(Double.self, forKey: .clickScale) ?? 1,
            clickColor: container.decodeIfPresent(StudioColor.self, forKey: .clickColor) ?? .white,
            clickStyle: container.decodeIfPresent(ClickRippleStyle.self, forKey: .clickStyle) ?? .outline,
            showsClickPress: container.decodeIfPresent(Bool.self, forKey: .showsClickPress) ?? true,
            cursorSmoothing: container.decodeIfPresent(CursorSmoothing.self, forKey: .cursorSmoothing)
                ?? .smooth,
            zoomStyle: container.decodeIfPresent(ZoomAnimationStyle.self, forKey: .zoomStyle) ?? .smooth,
            motionBlur: container.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0.5,
            canvas: container.decodeIfPresent(StudioCanvas.self, forKey: .canvas) ?? .identity,
            showsZooms: container.decodeIfPresent(Bool.self, forKey: .showsZooms) ?? true
        )
    }
}
