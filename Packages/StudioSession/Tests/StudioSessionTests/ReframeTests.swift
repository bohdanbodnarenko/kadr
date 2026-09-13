import CoreGraphics
import Foundation
import Testing
@testable import StudioSession

/// Turning a landscape recording into a portrait one (docs/09 U3.5).
///
/// The crop is the easy half. The interesting problem is what happens to the camera: a
/// 16:9 recording reframed to 9:16 loses two thirds of its width, and a zoom anchored to
/// something in the lost part now points at nothing.
@Suite("Reframe")
struct ReframeTests {
    private let landscape = CGSize(width: 1920, height: 1080)

    // MARK: - Geometry

    @Test("The original aspect changes nothing")
    func originalIsIdentity() {
        let reframe = Reframe.original
        #expect(reframe.isIdentity)
        #expect(reframe.outputSize(for: landscape) == landscape)
        #expect(reframe.sourceRect(for: landscape) == CGRect(origin: .zero, size: landscape))
    }

    @Test("Every preset produces its advertised shape", arguments: ReframeAspect.allCases)
    func aspectRatios(aspect: ReframeAspect) {
        let output = Reframe(aspect: aspect).outputSize(for: landscape)
        guard let ratio = aspect.ratio else {
            #expect(output == landscape)
            return
        }
        #expect(abs(output.width / output.height - ratio) < 0.001)
    }

    /// A soft picture of a screen is immediately obvious in a way a soft photograph is not,
    /// so the output never exceeds the source in either dimension.
    @Test("Reframing never upscales", arguments: ReframeAspect.allCases)
    func neverUpscales(aspect: ReframeAspect) {
        let output = Reframe(aspect: aspect).outputSize(for: landscape)
        #expect(output.width <= landscape.width + 0.001)
        #expect(output.height <= landscape.height + 0.001)
    }

    @Test("Filling crops; showing everything does not")
    func fillVersusFit() {
        let fill = Reframe(aspect: .nineSixteen, fill: .fill).sourceRect(for: landscape)
        let fit = Reframe(aspect: .nineSixteen, fill: .fit).sourceRect(for: landscape)

        #expect(fill.width < landscape.width, "a fill crops the sides")
        #expect(fit == CGRect(origin: .zero, size: landscape), "a fit keeps everything")
    }

    /// The interesting part of a screen recording is rarely dead centre — a sidebar-heavy
    /// app puts it well left.
    @Test("The crop can be biased away from the centre")
    func bias() {
        let left = Reframe(aspect: .nineSixteen, horizontalBias: 0).sourceRect(for: landscape)
        let right = Reframe(aspect: .nineSixteen, horizontalBias: 1).sourceRect(for: landscape)

        #expect(left.minX == 0)
        #expect(abs(right.maxX - landscape.width) < 0.001)
    }

    @Test("The crop always stays inside the recording", arguments: [0.0, 0.5, 1.0])
    func cropStaysInside(bias: Double) {
        let rect = Reframe(aspect: .square, horizontalBias: bias, verticalBias: bias)
            .sourceRect(for: landscape)
        #expect(CGRect(origin: .zero, size: landscape).insetBy(dx: -0.001, dy: -0.001).contains(rect))
    }

    @Test("A degenerate recording size does not divide by zero")
    func zeroSize() {
        #expect(Reframe(aspect: .square).outputSize(for: .zero) == .zero)
    }

    // MARK: - Re-planning the camera

    /// Through the path the renderer actually takes (docs/11 S2).
    ///
    /// These used to call `Reframe.replanning`, which was a second implementation of the
    /// same rules that nothing in production called — `StudioRenderPlan` goes through
    /// `StudioEdit.renderableZooms`. Two implementations of one behaviour, with the tests
    /// pointed at the one that never runs, is a worse position than having no tests: it
    /// reads as covered.
    private func replanned(_ cues: [ZoomCue], reframe: Reframe) -> [ZoomCue] {
        var edit = StudioEdit.untouched(duration: 10)
        edit.reframe = reframe
        edit.zooms = cues
        return edit.renderableZooms(in: landscape)
    }

    /// Leaving an anchor outside the crop would zoom to somewhere off screen, showing the
    /// viewer a corner of the frame and nothing else.
    @Test("An anchor outside the crop is pulled inside it")
    func anchorsArePulledInside() throws {
        let reframe = Reframe(aspect: .nineSixteen)
        let crop = reframe.sourceRect(for: landscape)
        // Far left, which a 9:16 crop of a 16:9 recording certainly loses.
        let cue = ZoomCue(start: 0, duration: 1, anchor: .fixed(CGPoint(x: 20, y: 540)))

        let replanned = try #require(replanned([cue], reframe: reframe).first)
        let anchor = replanned.anchor.point(in: landscape)
        #expect(anchor.x >= crop.minX - 0.001)
        #expect(anchor.x <= crop.maxX + 0.001)
    }

    @Test("An anchor already inside the crop is left where it is")
    func anchorsInsideAreKept() throws {
        let reframe = Reframe(aspect: .nineSixteen)
        let centre = CGPoint(x: 960, y: 540)
        let cue = ZoomCue(start: 0, duration: 1, anchor: .fixed(centre))

        let replanned = try #require(replanned([cue], reframe: reframe).first)
        #expect(replanned.anchor.point(in: landscape) == centre)
    }

    /// A 16:9 recording cropped to 9:16 is already about three times closer; applying the
    /// original 2× on top of that shows four pixels.
    @Test("Magnification is reduced by however much the crop already zoomed")
    func magnificationIsReduced() throws {
        let reframe = Reframe(aspect: .nineSixteen)
        let cue = ZoomCue(start: 0, duration: 1, magnification: 3, anchor: .centre)

        let replanned = try #require(replanned([cue], reframe: reframe).first)
        #expect(replanned.magnification < 3)
    }

    /// A cue that would zoom *out* is a cue that does nothing.
    @Test("Magnification never falls below one")
    func magnificationNeverInverts() throws {
        let reframe = Reframe(aspect: .nineSixteen)
        let cue = ZoomCue(start: 0, duration: 1, magnification: 1.1, anchor: .centre)

        let replanned = try #require(replanned([cue], reframe: reframe).first)
        #expect(replanned.magnification >= 1)
    }

    @Test("Without a reframe the cues are untouched")
    func identityLeavesCuesAlone() {
        let cues = [ZoomCue(start: 0, duration: 1, magnification: 2, anchor: .fixed(CGPoint(x: 20, y: 20)))]
        #expect(replanned(cues, reframe: .original) == cues)
    }

    @Test("Showing everything needs no re-planning, because nothing was cropped")
    func fitNeedsNoReplanning() {
        let cues = [ZoomCue(start: 0, duration: 1, magnification: 2, anchor: .fixed(CGPoint(x: 20, y: 20)))]
        #expect(replanned(cues, reframe: Reframe(aspect: .nineSixteen, fill: .fit)) == cues)
    }

    @Test("A reframe round-trips")
    func roundTrips() throws {
        let reframe = Reframe(aspect: .fourFive, fill: .fit, horizontalBias: 0.2)
        let data = try JSONEncoder().encode(reframe)
        #expect(try JSONDecoder().decode(Reframe.self, from: data) == reframe)
    }
}

/// The edit, and the looks that can be applied to it (docs/09 U3.5).
@Suite("Studio edit")
struct StudioEditTests {
    private let size = CGSize(width: 1920, height: 1080)

    @Test("A fresh recording starts with everything, unchanged")
    func untouched() {
        let edit = StudioEdit.untouched(duration: 30)
        #expect(abs(edit.duration - 30) < 0.001)
        #expect(edit.zooms.isEmpty)
        #expect(edit.reframe.isIdentity)
        #expect(edit.showsCursor)
        #expect(edit.showsZooms)
        #expect(edit.cursorScale == 1)
        #expect(edit.cursorSmoothing == .smooth)
        #expect(abs(edit.motionBlur - 0.5) < 0.0001)
        #expect(edit.clickStyle == .outline)
        #expect(edit.showsClickPress)
        #expect(edit.zoomStyle == .smooth)
        #expect(!edit.mutesAudio)
        #expect(!edit.mixesToMono)
    }

    @Test("A free crop is applied before the aspect reframe")
    func freeCropThenReframe() {
        var edit = StudioEdit.untouched(duration: 1)
        edit.cropRect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let free = edit.pixelCrop(in: size)
        #expect(abs(free.minX - size.width * 0.25) < 0.001)
        #expect(abs(free.width - size.width * 0.5) < 0.001)

        edit.reframe = Reframe(aspect: .square, fill: .fill)
        let combined = edit.sourceRect(for: size)
        #expect(combined.minX >= free.minX - 0.001)
        #expect(combined.maxX <= free.maxX + 0.001)
        #expect(combined.width <= free.width + 0.001)
    }

    @Test("A missing crop is the whole frame")
    func noCropIsIdentity() {
        let edit = StudioEdit.untouched(duration: 1)
        #expect(edit.pixelCrop(in: size) == CGRect(origin: .zero, size: size))
        #expect(edit.sourceRect(for: size) == CGRect(origin: .zero, size: size))
    }

    @Test("An old edit without a crop field still opens")
    func cropDefaultsAbsent() throws {
        let json = #"{"version": 1}"#
        let edit = try JSONDecoder().decode(StudioEdit.self, from: Data(json.utf8))
        #expect(edit.cropRect == nil)
        #expect(edit.cursorScale == 1)
        #expect(edit.clickScale == 1)
        #expect(edit.clickColor == .white)
        #expect(edit.clickStyle == .outline)
        #expect(edit.showsClickPress)
        #expect(edit.zoomStyle == .smooth)
        #expect(edit.cursorSmoothing == .smooth)
        #expect(edit.motionBlur == 0.5)
        #expect(edit.keystrokeAppearance == .dark)
        #expect(!edit.mutesAudio)
        #expect(!edit.mixesToMono)
    }

    @Test("Absurd pointer sizes are clamped")
    func cursorScaleIsClamped() {
        var edit = StudioEdit(cursorScale: 99)
        #expect(edit.cursorScale == StudioEdit.maximumCursorScale)
        edit.cursorScale = 0
        #expect(edit.cursorScale == StudioEdit.minimumCursorScale)
    }

    @Test("Absurd ripple sizes are clamped")
    func clickScaleIsClamped() {
        var edit = StudioEdit(clickScale: 99)
        #expect(edit.clickScale == StudioEdit.maximumCursorScale)
        edit.clickScale = 0
        #expect(edit.clickScale == StudioEdit.minimumCursorScale)
    }

    @Test("Motion blur is clamped to a fraction")
    func motionBlurIsClamped() {
        var edit = StudioEdit(motionBlur: 9)
        #expect(edit.motionBlur == 1)
        edit.motionBlur = -1
        #expect(edit.motionBlur == 0)
    }

    @Test("A look carries pointer motion and ripple style")
    func presetCarriesCursorLook() {
        var edit = StudioEdit.untouched(duration: 8)
        edit.cursorSmoothing = .natural
        edit.motionBlur = 0.2
        edit.clickStyle = .filled
        edit.showsClickPress = false
        edit.zoomStyle = .dynamic
        let preset = StudioPreset(name: "Soft", capturing: edit)
        let applied = preset.applied(to: .untouched(duration: 8))
        #expect(applied.cursorSmoothing == .natural)
        #expect(abs(applied.motionBlur - 0.2) < 0.0001)
        #expect(applied.clickStyle == .filled)
        #expect(!applied.showsClickPress)
        #expect(applied.zoomStyle == .dynamic)
        #expect(preset.matches(applied))
    }

    @Test("Absurd caption sizes are clamped")
    func overlayScaleIsClamped() {
        var edit = StudioEdit(keystrokeScale: 9, captionScale: 0)
        #expect(edit.keystrokeScale == StudioEdit.maximumOverlayScale)
        #expect(edit.captionScale == StudioEdit.minimumOverlayScale)
        edit.captionScale = 99
        #expect(edit.captionScale == StudioEdit.maximumOverlayScale)
    }

    /// Changing the aspect ratio must re-plan the camera immediately, not leave cues
    /// pointing off the new frame.
    @Test("Renderable zooms reflect the reframe")
    func renderableZoomsAreReplanned() throws {
        var edit = StudioEdit.untouched(duration: 10)
        edit.zooms = [ZoomCue(start: 0, duration: 2, magnification: 3, anchor: .fixed(CGPoint(x: 20, y: 540)))]
        edit.reframe = Reframe(aspect: .nineSixteen)

        let renderable = try #require(edit.renderableZooms(in: size).first)
        #expect(renderable.magnification < 3)
        #expect(renderable.anchor.point(in: size).x > 20)
    }

    @Test("A pointer-follow zoom stays a pointer-follow zoom after a reframe")
    func pointerFollowSurvivesReframe() throws {
        var edit = StudioEdit.untouched(duration: 10)
        edit.zooms = [ZoomCue(start: 0, duration: 2, magnification: 3, anchor: .pointer)]
        edit.reframe = Reframe(aspect: .nineSixteen)

        let renderable = try #require(edit.renderableZooms(in: size).first)
        #expect(renderable.anchor == .pointer)
        #expect(renderable.magnification < 3)
    }

    @Test("Disabled zooms and a master off switch never render")
    func disabledZoomsAreOmitted() {
        var edit = StudioEdit.untouched(duration: 10)
        edit.zooms = [
            ZoomCue(start: 0, duration: 2, isEnabled: false),
            ZoomCue(start: 4, duration: 2)
        ]
        #expect(edit.renderableZooms(in: size).map(\.start) == [4])
        edit.showsZooms = false
        #expect(edit.renderableZooms(in: size).isEmpty)
    }

    // MARK: - Presets

    /// Somebody trying a vertical layout has not asked to lose their cuts, and a preset
    /// that could do that is a preset nobody dares try.
    @Test("Applying a look never touches the clips or the zooms")
    func presetsLeaveContentAlone() {
        var edit = StudioEdit.untouched(duration: 20)
        edit.clips.split(atEdited: 5)
        edit.zooms = [ZoomCue(start: 1, duration: 2)]

        let applied = StudioPreset(name: "Vertical", reframe: Reframe(aspect: .nineSixteen)).applied(to: edit)
        #expect(applied.clips == edit.clips)
        #expect(applied.zooms == edit.zooms)
        #expect(applied.reframe.aspect == .nineSixteen)
    }

    /// Applying a preset must not stop matching the instant it is applied.
    @Test("A preset matches the edit it was just applied to")
    func matchesAfterApplying() {
        let preset = StudioPreset(name: "Vertical", reframe: Reframe(aspect: .nineSixteen))
        let edit = preset.applied(to: .untouched(duration: 10))
        #expect(preset.matches(edit))
    }

    @Test("Changing anything stops the match")
    func editingBreaksTheMatch() {
        let preset = StudioPreset(name: "Vertical", reframe: Reframe(aspect: .nineSixteen))
        var edit = preset.applied(to: .untouched(duration: 10))
        #expect(preset.matches(edit))

        edit.camera.isVisible = false
        #expect(!preset.matches(edit))
    }

    @Test("A different name is still the same look")
    func nameIsNotPartOfTheLook() {
        let edit = StudioPreset(name: "One", reframe: Reframe(aspect: .square)).applied(to: .untouched(duration: 5))
        #expect(StudioPreset(name: "Another", reframe: Reframe(aspect: .square)).matches(edit))
    }

    @Test("A preset carries pointer size")
    func presetCarriesCursorScale() {
        var edit = StudioEdit.untouched(duration: 8)
        edit.cursorScale = 2
        let preset = StudioPreset(name: "Large pointer", capturing: edit)
        let applied = preset.applied(to: .untouched(duration: 8))
        #expect(applied.cursorScale == 2)
        #expect(preset.matches(applied))
    }

    @Test("A preset carries ripple size")
    func presetCarriesClickScale() {
        var edit = StudioEdit.untouched(duration: 8)
        edit.clickScale = 2
        let preset = StudioPreset(name: "Large ripples", capturing: edit)
        let applied = preset.applied(to: .untouched(duration: 8))
        #expect(applied.clickScale == 2)
        #expect(preset.matches(applied))
    }

    @Test("A preset carries ripple colour")
    func presetCarriesClickColor() {
        var edit = StudioEdit.untouched(duration: 8)
        edit.clickColor = StudioColor(red: 1, green: 0.2, blue: 0.1)
        let preset = StudioPreset(name: "Red ripples", capturing: edit)
        let applied = preset.applied(to: .untouched(duration: 8))
        #expect(applied.clickColor == edit.clickColor)
        #expect(preset.matches(applied))
    }

    @Test("A saved look does not take another session's wallpaper file with it")
    func presetDropsWallpaperFileName() {
        var edit = StudioEdit.untouched(duration: 8)
        edit.canvas.background = .wallpaper
        edit.canvas.wallpaperFileName = "wallpaper.png"
        let preset = StudioPreset(name: "Wall", capturing: edit)
        #expect(preset.canvas.wallpaperFileName == nil)
        var destination = StudioEdit.untouched(duration: 8)
        destination.canvas.wallpaperFileName = "other.png"
        destination.canvas.background = .wallpaper
        let applied = preset.applied(to: destination)
        #expect(applied.canvas.wallpaperFileName == "other.png")
    }

    @Test("An edit round-trips whole")
    func editRoundTrips() throws {
        var edit = StudioEdit.untouched(duration: 12)
        edit.clips.split(atEdited: 4)
        edit.zooms = [ZoomCue(start: 1, duration: 2, magnification: 2)]
        edit.reframe = Reframe(aspect: .square)
        edit.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        edit.camera = .rectangle
        edit.showsKeystrokes = false
        edit.cursorScale = 2
        edit.canvas = .presenter
        edit.keystrokePlacement = .topLeading
        edit.captionPlacement = .bottomTrailing
        edit.keystrokeScale = 1.4
        edit.captionScale = 0.8
        edit.keystrokeAppearance = .light
        edit.soundtrackFileName = "soundtrack.m4a"
        edit.soundtrackDisplayName = "Voice"
        edit.cursorSmoothing = .natural
        edit.motionBlur = 0.8
        edit.clickStyle = .filled
        edit.showsClickPress = false
        edit.zoomStyle = .dynamic

        let data = try JSONEncoder().encode(edit)
        #expect(try JSONDecoder().decode(StudioEdit.self, from: data) == edit)
    }

    /// An edit written by a later Kadr still opens — it simply arrives without whatever
    /// was added.
    @Test("Unknown fields are ignored, not fatal")
    func unknownFieldsAreIgnored() throws {
        let json = #"{"version": 9, "chapters": [{"title": "one"}]}"#
        let edit = try JSONDecoder().decode(StudioEdit.self, from: Data(json.utf8))
        #expect(edit.version == 9)
        #expect(edit.clips.isEmpty)
        #expect(edit.showsCursor)
        #expect(edit.showsZooms)
        #expect(edit.cursorScale == 1)
    }

    @Test("A preset with nothing in it at all decodes")
    func emptyPreset() throws {
        let preset = try JSONDecoder().decode(StudioPreset.self, from: Data("{}".utf8))
        #expect(preset.name == "Untitled")
        #expect(preset.reframe.isIdentity)
    }

    /// The edit is the only input to a render besides the footage, which is what makes
    /// "has this changed" an exact question (docs/09 U3.1).
    @Test("The same edit always hashes the same way")
    func editDigestIsStable() {
        var edit = StudioEdit.untouched(duration: 10)
        edit.zooms = [ZoomCue(id: UUID(), start: 1, duration: 2)]
        #expect(RenderStamp.digest(of: edit) == RenderStamp.digest(of: edit))
    }

    @Test("Any change to the edit changes its hash")
    func editDigestChanges() {
        let edit = StudioEdit.untouched(duration: 10)
        var changed = edit
        changed.showsClicks = false
        #expect(RenderStamp.digest(of: edit) != RenderStamp.digest(of: changed))
    }
}
