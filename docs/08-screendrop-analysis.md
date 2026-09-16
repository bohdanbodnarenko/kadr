> The parity table in this document is **partial**. Recording, telemetry and studio exist,
> but several ports are incomplete relative to Screendrop. The live gap list is
> `docs/16-screendrop-parity-plan.md`.

# Screendrop Analysis — What to Learn, What to Port, What to Avoid

> Source-level study of Screendrop (fayazara, CC0-licensed CleanShot alternative; ~42.6k lines, 176 Swift files) against Kadr's implemented M0–M18 state. Conclusion up front: **Screendrop validates Kadr's thesis twice** — its editor and recording *features* are 12–18 months ahead of our spec and largely adoptable, while its *architecture* (one flat target, one process, zero tests, SwiftUI shell, `screencapture` CLI for stills, macOS 26.4 floor) is exactly the debt our three-process layered design avoids. Port the features, keep our bones.

## 1. License reality — read before porting anything

- The repo is **CC0 1.0** → its own code is legally reusable in MIT Kadr.
- **Exception: `Engine/` is a port of tldraw** (file headers say so; `Engine/PathBuilder.swift:7` cites tldraw's repo path). tldraw's license is **not permissive** (watermark/commercial restrictions), and a downstream CC0 grant cannot launder it. Treat `Engine/*` (shapes, selection, arrows, text engine) exactly like we treat QuickRecorder/Capso: **read-only reference — reimplement behaviors in our own `AnnotationCommand` model, never copy.** (The freehand stroke math likely traces to MIT `perfect-freehand`; verify before lifting even that.)
- Strip on contact: wallpaper-pack CDN downloads, `CloudUploader`/sidecar upload code, Sparkle config, branding. Rule 1 (zero network) applies to everything we port.

## 2. Where Screendrop is better than Kadr today

### Editing (their crown jewel — and CC0-clean, outside Engine/)

1. **Background/beautify subsystem** (`AnnotationBackground.swift` 659 lines, `-Layout`, `-Renderer`): normalized-to-shortest-edge padding/radius/shadow so presets keep visual weight across sizes; 16 curated solids + 16 three-stop gradients; **9-way alignment where stuck edges get zero padding and the touching corners lose their radius** (the CleanShot "bleeds off the bottom" look); shadow drawn with an even-odd exterior knockout so translucent screenshots aren't backed by black; wallpaper decode via bucketed `CGImageSourceCreateThumbnailAtIndex` sizes in a 192 MB NSCache. Pure CG/CI, dependency-free, drops into our `AnnotationModel`/`AnnotationRender` split almost by design (`AnnotationBackgroundLayout` is already a pure function `contentSize + settings → canvas/card/image rects`).
2. **3D perspective camera** (`AnnotationCameraGeometry.swift`): real pinhole model (tilt/orbit/roll/FOV/zoom/pan) → quad → hand-derived **invertible 3×3 homography, so hit-testing works through the projection**; rendered with `CIFilter.perspectiveTransform` drawn via `CIContext(cgContext:)` to avoid an extra full-canvas bitmap. ~700 self-contained lines. We have nothing like it.
3. **Progressive blur** (radial/directional; `.clipped` to the screenshot or `.bleed` across the whole composed scene) with the **settle-preview pattern**: a cheap N-level SwiftUI approximation live while dragging, real CoreImage render on idle. The pattern generalizes to every expensive editor effect.
4. **Smart redaction, finished** (`SmartRedactionRecognizer.swift`): Vision text + rules for emails/URLs/IPs/phones, **Luhn-checked cards**, JWTs, known API-key prefixes, generic-token heuristics, and a `password:`/`token=` rule that redacts **only the value substring** using `boundingBox(for: range)` sub-line boxes; overlap merge + dedupe. This is our M18 feature done better — port the recognizer into VisionServices, keep our XPC isolation, add our per-cell pixelate jitter on top (theirs has none — we're stronger there).
5. **Arrow bindings**: arrows attach to shapes via normalized anchors and follow when the target moves, trimming at its edge. Engine/-tainted, so **reimplement** as an `AnnotationCommand` relationship — it's the single most differentiating annotation behavior.
6. **Preset systems**: named presets capturing the whole background+camera+blur+border+watermark state, with active-preset tracking, "edited vs matches preset" comparison, a UserDefaults recovery copy, and schema-migrating Codable discipline everywhere (`decodeIfPresent` defaults; even an abandoned feature's key is retained so old documents stay readable).
7. **Inspector micro-UX** (`AnnotationInspectorSlider.swift`): "label-in-track" scrubber (whole field is the track), click-to-edit numeric entry parsing "45%", "12px", "30deg", "1.5×", arrow-key stepping. Better than any slider in our spec.
8. Smaller editor wins: borders + tiled watermarks (we have neither); live `NSTextView` overlay measured by the same CoreText layout as rendering (true WYSIWYG); crop handle-margin trick (fit-zoom insets so handles stay reachable at edges); `AnnotationImageCropper`'s integral-pixel-rect remap contract; import-from-Finder as copy-then-edit.

### Recording (Screen-Studio-grade, mostly CC0-clean)

9. **Cursor/click reconstruction from telemetry** — the standout: records the screen with `showsCursor = false` and captures input separately (`RecordingPointerCapture.swift`, 774 lines): listen-only CGEvent tap with documented triple fallback (AppKit monitors for presses, 60 Hz sampler only if the tap dies), **captures the actual cursor artwork** (`NSCursor.currentSystem` PNGs + hotspots at 30 Hz), per-frame window geometry from SCK attachments, pause-aware timestamps. Reconstruction re-integrates along the **edited** timeline with one shared damped spring (`RecordingMotionSpring.swift`) so cursor and camera settle identically; presses stay pixel-exact while motion smooths. Keystroke capture is privacy-filtered by design: chords and special keys only, "plain typing never lands in the sidecar."
10. **Virtual camera / smooth zooms** (`RecordingViewportTimeline.swift`): zoom **cues** as editable data, auto-generated from click clusters; smart anchors with immutable cluster centers (no camera dithering); spring-integrated at fixed rate along the edited timeline so cuts never interrupt a zoom; **motion-blur supersampling over one output-frame shutter** at export — the reason their zooms look like Screen Studio's. Preview and export interpolate the same precomputed timeline: determinism by construction.
11. **Session package design** (`RecordingSession.swift`): `.screendroprec` directory = `screen.mov` + `camera.mov` + `input.json` + `edit.json` + `edit.draft.json` (autosave separate from explicit save) + `render.json` (a **render stamp** proving a cached export matches the current edit) + `poster.jpg`, living in App Support so a crash never hands footage to the tmp purger; recovery coordinator reopens orphans.
12. Also worth taking: non-destructive clip cuts + per-clip 1–8× speed via `AVMutableComposition.scaleTimeRange` (audio stays synced); social aspect reframe (16:9/9:16/1:1/4:5 with camera re-planning); transcript-driven editing (filler-word + silence cut planning as pure functions — their transcriber is macOS-26-only, we'd pair the planner with `SFSpeechRecognizer` or gate it); camera bubble as a separately-recorded source; `NotchBarTrimmer`'s pixel-exact notch strip removal.

### UX

13. **Preview stack mechanics**: the always-on panel publishes `interactiveRects` (screen-space frames of interactive elements) and passes mouse events through everywhere else — the correct solution to transparent-overlay hit-testing. Plus: **peek-collapse** to an edge tab instead of hiding (no show/hide races), engagement tracking that permanently cancels auto-close once the user touches an item, unsaved-item awareness at quit, and a capture-exclusion registry for all app windows.
14. **After-capture action matrix** (`AfterCaptureActions.swift`): per-capture-type toggles for overlay/copy/save/annotate/pin/open-editor — a matrix beats our single default-action choice.
15. **Card layout editor**: 9 actions placeable into 4 corner slots + a center pill column by drag-and-drop onto a live mock card in Settings. CleanShot doesn't have this either.
16. "Compress" as a first-class card action with a savings badge — original, cheap, useful.

## 3. Where Kadr is better (keep, don't regress)

Process split + <30 MB agent (their editor RAM can never be reclaimed — everything is one process); 13 tested packages vs zero tests (~575 tests vs "build success is the only verification" per their AGENTS.md); ScreenCaptureKit stills vs shelling out to `/usr/sbin/screencapture` (note their documented reason — SCK display capture drops inter-window shadows — as a real caveat we should handle deliberately); macOS 14 floor vs 26.4; CALayer-per-shape editor rendering vs full-view redraw per drag frame; command-stack undo vs 200-snapshot stack ×2 disjoint systems (their crop has its own undo — ⌘Z means different things in different modes); zero network vs in-app uploader; onboarding (they have none); pixelate jitter (ours is at least attempted; theirs is a plain downsample); Developer-ID discipline both have.

## 3a. Status, 2026-09-01

Everything in the table below has since been built. The last four to land were the ones the
recording and editing experience was actually judged on, and they are worth naming because
each was a *whole missing affordance* rather than a rough edge:

- **Stopping a recording.** There was no on-screen way at all — only the menu-bar dropdown.
  Now a floating bar (Stop/Pause/Discard, draggable, excluded from the capture, never takes
  key status), the record hotkey toggling, and a dedicated ⌃⇧. .
- **Deciding mic/system-sound/camera before recording.** Settings-only, so recording a demo
  with your voice meant leaving the thing you were about to record. Now folded into the
  countdown, which itself was missing — a still got a self-timer and a recording did not.
- **Watching a video edit.** The preview scrubbed and could not play, so a zoom, a cut or a
  speed change could only be judged by exporting and waiting. Space plays; the timeline
  zooms to sixty times the window, because fit-to-window is 1.3 points a second on a
  ten-minute recording and "split here" was a guess.
- **Leaving crop mode in the screenshot editor.** docs/03 §3 says "Crop is a mode until
  **Done**" and there was no Done.

## 4. Full verdict table

| Capability | Screendrop vs Kadr today | Action |
|---|---|---|
| Background/beautify + alignment-stuck edges | Better | Port (U1.1) |
| Background/style preset stores | Better (absent here) | Port pattern (U1.5) |
| 3D perspective camera | Better (absent) | Port (U1.2) |
| Progressive blur + settle-preview | Better (absent) | Port (U1.3) |
| Border + watermark | Better (absent) | Port (U1.4) |
| Smart redaction recognizer | Better than our M18 | Port into VisionServices (U1.6) |
| Arrow bindings | Better (absent) — Engine/tainted | Reimplement (U1.7) |
| Inspector slider control | Better | Port (U1.5) |
| Non-destructive sidecar docs | Shipping vs our planned `.kadr` | Adopt versioning discipline (U1.8) |
| Import-from-Finder copy-then-edit | Better (unspecified here) | Adopt (U1.8) |
| Text tool | Mixed — live NSTextView better; no style presets | Take overlay technique only |
| Crop | Parity math; no expand-canvas | Take `CropRectEditor` math + margin trick |
| Undo model | Worse | Keep ours |
| Editor rendering arch | Worse (full redraw) + license taint | Keep ours |
| Pixelate anti-reversal | Worse | Keep ours; finish M3 jitter |
| Cursor/click telemetry + reconstruction | Far better | Port design (U3.1–U3.2) |
| Zoom cues + spring camera + motion blur | Far better | Port design (U3.3) |
| Clips + per-clip speed | Better | Port (U3.4) |
| Session package + render stamp | Better | Adopt (U3.1) |
| Transcript editing / filler removal | Better (macOS 26 APIs) | Port planner, gate transcriber (U3.6) |
| Social reframe / camera bubble / teleprompter | Better | U3.5 / U3.4 / backlog |
| Preview-stack hit-testing + collapse + engagement | Better | Port (U2.1) |
| After-capture matrix | Better | Port (U2.2) |
| Card layout editor | Better | Port (U2.3) |
| Still-capture pipeline, process model, tests, idle RAM, onboarding, network stance | Worse | Keep ours — this is the moat |

## 5. Porting ground rules

Every port lands in our layered packages with the tests Screendrop never wrote: pure math/models → `AnnotationModel`/`Shared` with table-driven tests; rendering → `AnnotationRender`; Vision work → `VisionServices` behind XPC; recording telemetry/timelines → `RecordingCore` (+ a future `StudioCore`); all UI stays SwiftUI-inside-NSHostingView in the editor app, never the agent. Nothing from `Engine/` is copied. Nothing that touches the network survives the port. Agent idle budget is untouchable — every new capability must show a zero-delta idle `phys_footprint` run in CI before merge.
