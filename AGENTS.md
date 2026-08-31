## Learned User Preferences
- Treat `/Users/bohdanbodnarenko/Developer/personal/Screendrop` as the working reference for capture permission handling, editor UX, and the post-capture corner overlay; match or exceed Screendrop and CleanShot X rather than inventing a weaker flow.
- When given a docs line range, implement that section fully following industry best practices.
- Never re-prompt for screen recording when System Settings already shows the grant.
- The annotation editor should feel polished: captured images centered, chrome comparable to Screendrop/CleanShot X.
- After placing a one-shot annotation (arrow, shape, line, text, blur), switch back to Select; counters, pencil, and highlighter stay armed so they can be used repeatedly.
- Editor and studio sliders should match Screendrop: a labeled scrub track plus a persistent typed value field. Settings panes keep the system slider.
- Annotation resize handles must be hittable in window/screen space on the shape’s real corners (and edges), like Screendrop — not decorative overlays and not image-space hit tests that miss when zoomed out.

## Learned Workspace Facts
- Screendrop is a sibling local macOS capture app used as the behavioral reference for Kadr.
- On macOS 15+, `SCShareableContent` can re-present the "record this computer's screen and audio" sheet even when Screen Recording is already granted; capture must TCC-preflight (`CGPreflightScreenCaptureAccess`, then `CGRequestScreenCaptureAccess` only if needed) before any ScreenCaptureKit call.
- After a new screen-recording grant, macOS often requires quitting and reopening Kadr before ScreenCaptureKit honors it.
- Annotations are stored in screenshot coordinates but must draw and export on the full canvas, including beautify padding/background — not clipped to the capture card.
- The post-capture corner overlay hides without deleting (×, Esc, peek tab); hover pauses auto-dismiss and retries after the pointer leaves, rather than canceling hide forever.
- Speech and transcription (docs/13) run in HelperTools: the agent must not link Speech, and live-follow authorization happens in the helper.
- KadrEditor is a separate app from the agent; rebuilding or relaunching only `Kadr` does not update EditorUI — rebuild/install the editor (e.g. `make install`) to pick up editor changes.
