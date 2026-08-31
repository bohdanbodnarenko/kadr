# PRD — Kadr

> A free, open-source, native macOS screen-capture app: the CleanShot X / ShotBase alternative that costs nothing, sends nothing, and idles at almost zero RAM.
> **Hard product stance:** 100% local. No hosting, no upload targets, no share-by-URL — sharing is drag-and-drop (and the native share sheet). The editor is a first-class pillar, not an afterthought.
> Companion docs: `01-competitive-analysis.md` (market), `03-features.md` (full feature specs), `04-swift-architecture.md` (technical design), `05-cross-platform-gpui.md` (Rust/gpui evaluation).

---

## 1. Vision

Screenshots are a dozens-of-times-a-day workflow for developers, designers, support teams, and writers — yet the best tools are paid ($29 + $96/yr cloud for CleanShot; $156–300/yr for ShotBase), and the free ones are either Apple's minimal built-in, non-native ports that fight Gatekeeper, or abandoned Electron apps.

**Kadr is the tool that ends that tradeoff:** a native Swift menu-bar app with CleanShot-grade workflow, Shottr-grade performance, and a strict local-first privacy posture — MIT-licensed, signed and notarized, updated via Sparkle, forever free.

## 2. Product principles

1. **The overlay is the product; drag-and-drop is the sharing model.** Capture → floating thumbnail → drag into any app (Slack, Mail, Figma, Finder, browser). Every feature routes through this flow; nothing forces a save dialog, a library visit — or a URL. There is no upload feature, period.
2. **The editor is a pillar, not a bonus.** A CleanShot-grade, non-destructive annotation editor (arrows, blur/pixelate, counters, text, crop, beautify backgrounds, redaction) is a headline reason to install, and everything edited flows back out via drag-and-drop.
3. **Performance is a feature with a budget.** Idle RSS, capture latency, and app size are tracked in CI with hard limits (§8). Regressions are release blockers, same as crashes.
4. **Local-only, zero network.** No account, no analytics, no hosting, no cloud — the only network calls the app can ever make are the Sparkle update check and, if the user presses the button that says so, asking macOS to install an on-device speech model. The agent binary links no other networking code (CI-enforced). This is stronger than "local-first": there is nothing to opt out of.
5. **Native or nothing.** AppKit window management, SwiftUI content, ScreenCaptureKit, Vision. If a feature can't be done natively and well, it waits.
6. **Scriptable by default.** URL scheme + CLI from v1, because power users are the distribution channel for OSS tools.

## 3. Target users & personas

| Persona | Day-to-day | What wins them |
|---|---|---|
| **Dev (primary)** — ships software, lives in terminal + Slack + GitHub | bug reports, PR screenshots, quick OCR of error text, recording repro GIFs | speed, hotkeys, drag-to-Slack overlay, GIF export, pixel ruler, CLI/URL scheme, zero subscription |
| **Designer** | UI reviews, redlines, sharing crops in Figma/Slack | pixel measurements, color picker (OKLCH/APCA), clean window shots with shadow/transparent background, beautify backgrounds |
| **Support/success/PM** | annotated how-tos, step-by-step guides, short screen recordings | counter badges, arrows/blur, scrolling capture, easy MP4/GIF, drag straight into tickets/chat |
| **Privacy-conscious pro** | screenshots containing customer data / secrets | on-device everything, auto-redaction, no accounts, auditable source |
| **Casual Mac user (secondary)** | occasional screenshots, saw it on a "best free Mac apps" list | it just works after 2-minute onboarding; feels Apple-native |

Non-targets (v1): Windows/Linux users (see §10 and doc 05), enterprise teams needing SSO/admin (out of scope), video-production users needing Screen-Studio-grade cinematic output.

## 4. Goals & success metrics

**Product goals (first year)**
- G1: A user coming from CleanShot X can do 90% of their daily workflow without missing features (capture modes, overlay, annotate, record, OCR, pin, hide-icons).
- G2: Performance credential established: measured idle RSS and capture latency published in README, better than every non-Shottr competitor.
- G3: Community traction: 10k+ GitHub stars, 20+ external contributors, Homebrew cask, coverage on HN/Product Hunt.

**Success metrics (all measurable without telemetry — via GitHub, Homebrew analytics, release download counts)**
- 50k downloads year one; 30% of installs updating within 2 weeks of a release (Sparkle appcast hit counts).
- Median time-to-first-capture after install < 2 minutes (measured in usability tests, not telemetry).
- CI perf gates green on every release: see budgets in §8.
- < 5% of GitHub issues about Gatekeeper/permissions (proves the onboarding works).

## 5. Scope — release phases

### Phase 1 — MVP "better than built-in" (target: 3 months)

The smallest product that beats ⇧⌘5 and earns daily use:

- Capture: area (with magnifier, dimension readout, remembered last region), window (SCK-clean, shadow toggle, transparent background), fullscreen, display; self-timer; capture-previous-area.
- Quick Access Overlay: floating corner thumbnail(s), drag-out, click actions (copy/save/annotate/delete), auto-dismiss, multi-capture stacking.
- Annotation editor v1: crop, arrow, rectangle/ellipse, line, freehand, text, highlighter, blur + pixelate, counter badges, undo/redo, copy/save/drag-out. Non-destructive (vector command model), re-editable while open.
- OCR: capture-text mode to clipboard (Vision), QR decode.
- Pin screenshot as floating window (opacity, click-through, nudge).
- Essentials: customizable global hotkeys, launch at login, PNG/JPEG/WebP/HEIC export, clipboard-first defaults, configurable save folder + filename template, Retina 2x→1x option, multi-display + Spaces correctness, permission onboarding flow, Sparkle updates, notarized DMG + Homebrew cask.

Explicitly **not** in MVP: recording, scrolling capture, backgrounds, history.

### Phase 2 — "replace CleanShot for most people" (months 4–8)

- Screen recording: MP4 (HEVC/H.264) via SCK; region/window/display; mic + system audio; pause/resume; click visualization; cursor toggle; recording HUD + menu-bar state; trim editor; **GIF export** (gifski-quality).
- Scrolling capture (vertical first): assisted auto-scroll + stitching, manual fallback mode.
- History: local capture history (configurable retention), quick strip in menu + browser window.
- Beautify: padding/background presets, gradients, custom image, aspect presets, auto-balance.
- Auto-redaction assist: detect emails/API keys/credit cards via Vision text + patterns, one-click blur all.
- Keystroke overlay for recordings; webcam overlay (PiP).
- Automation: URL scheme (CleanShot-compatible verbs where sensible) + `kadr` CLI; Shortcuts actions.
- Hide desktop icons; screen freeze; crosshair precision mode.

### Phase 3 — "beyond parity" (months 9+)

- OCR-indexed searchable history (fully local “find that screenshot with the stripe error”).
- Pixel ruler & measurement tools; color picker (OKLCH, APCA contrast) — the Shottr niche.
- Editor depth: background removal (Vision subject lift), smart selection, multi-image composition, re-editable `.kadr` project files, smart highlighter, spotlight.
- Optional: horizontal scrolling capture, HDR capture (macOS 15+ APIs), RecognizeDocumentsRequest table copy.

## 6. Non-goals

- **No sharing infrastructure of any kind** — no hosted cloud, no BYO-bucket uploads, no share-by-URL, no accounts, no teams/SSO. Sharing is drag-and-drop from the overlay/editor/history, plus the native macOS share sheet (AirDrop, Messages, Mail — all handled by the OS, not by us). If someone wants URL sharing they can drag into whatever service they already use.
- No telemetry/analytics of any kind, ever, including "anonymous" statistics. No network code in the app beyond the Sparkle update check and the user-initiated on-device speech-model install.
- No Mac App Store build initially (sandbox blocks scrolling-capture auto-scroll, custom save flows; MAS forbids Sparkle). Revisit later with a reduced MAS variant if demand exists.
- No Windows/Linux port in the Swift codebase; the cross-platform path is a Rust core extraction, decided per doc 05, not before Phase 3.
- No AI cloud features; on-device only (Vision, and only where it adds obvious value).

## 7. Platform & compatibility

- **Minimum macOS 14 (Sonoma).** Rationale: `SCScreenshotManager` + `SCContentSharingPicker` (14.0), Vision instance masks (14.0), `@Observable` (14.0). Fallback-free codebase beats supporting 12/13 with dual paths. Recording uses `SCStream`+`AVAssetWriter` on 14 and can adopt `SCRecordingOutput`/mic-in-SCK/HDR on 15+ behind availability checks.
- Apple Silicon native + Intel (universal binary) through Phase 2; re-evaluate Intel at Phase 3 by download stats.
- Localization-ready from v1 (String Catalogs); English at launch, community translations after.

## 8. Performance requirements (CI-enforced budgets)

| Metric | Budget | Measurement |
|---|---|---|
| Idle RSS (agent running, no windows) | **< 30 MB** target, 40 MB hard fail | `footprint`/`task_info` in CI perf test on release build |
| RSS after 10 captures + editor closed | back under 60 MB within 30 s (caches purged) | scripted UI test |
| Hotkey → selection overlay visible | **< 100 ms** (freeze-frame path, per display) | signpost timing in CI on reference hw |
| Selection → image on clipboard | < 150 ms for a 5K display region | signpost timing |
| App bundle size | < 15 MB DMG | CI check |
| Idle CPU | 0.0% (no timers, no polling). Sparkle's daily check is coalesced by `NSBackgroundActivityScheduler` rather than a repeating timer. | 60 s sample must show no wakeups from our code except that coalesced check |
| Cold launch to status item | < 150 ms | signpost `launchToStatusItem` |
| Cold launch to hotkeys armed | < 300 ms | signpost `launchToHotkeyArmed` |
| Recording overhead | < 15% CPU at 1080p60 HEVC on M1 | manual benchmark per release |
| Editor idle RSS (5K capture open) | < 120 MB warn / 180 MB fail | `check-perf.sh --editor` |
| Studio RSS (10-min session, scrubbed) | < 250 MB warn / 350 MB fail | `check-perf.sh --studio` |

Engineering strategy to meet these (details in doc 04): AppKit-first shell with no persistent SwiftUI scene at idle; lazy framework loading; editor in a separate process so Vision models and bitmaps die with the window; IOSurface end-to-end capture path; ImageIO-downsampled thumbnails; strict "no timers at idle" rule.

## 9. Privacy, security, distribution

- TCC Screen Recording permission requested through a dedicated onboarding screen that explains the macOS 15 monthly re-approval nag honestly; `SCContentSharingPicker` offered as a no-permission alternative path for window/screen capture.
- Signed with Developer ID + notarized (requires the $99/yr Apple developer membership — funded via GitHub Sponsors / OpenCollective); Sparkle 2 with EdDSA-signed appcast on GitHub Releases; Homebrew cask.
- Security posture: **Sparkle and the optional speech-model install are the only networking in the entire app** — no upload/share modules exist at all, so there is no credential storage and no exfiltration surface to audit; reproducible release builds as a stretch goal.
- License: **MIT** (max adoption/contribution). Third-party: KeyboardShortcuts (MIT), Sparkle (MIT), gifski (AGPL — use CLI-subprocess or MIT alternative; decide in implementation), reference-only for AGPL/BUSL projects.

## 10. Key risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| macOS TCC changes break capture UX each fall | high | track WWDC yearly; keep capture behind one internal API; beta-test on developer seeds; SCContentSharingPicker fallback |
| Scrolling capture robustness (the moat is hard) | med | ship assisted mode first (user scrolls, we stitch); auto-scroll via scroll-event synthesis as enhancement; extensive per-app test matrix |
| Solo-maintainer burnout (see ksnip) | high | small core + modular SPM packages to parallelize contributors; CONTRIBUTING + good-first-issues from day one; consider a 2–3 person core team before Phase 2 |
| $99/yr signing + no revenue | low | sponsors; many OSS Mac apps sustain this (e.g., Sparkle-ecosystem apps) |
| CleanShot ships a free tier / Apple Sherlocks more features | med | our moat is license + privacy + scriptability, not any single feature |
| gifski AGPL / codec licensing | low | subprocess isolation or alternative encoder; H.264/HEVC via system VideoToolbox (no license issue) |

## 11. Open questions (decide before implementation)

1. ~~Final name + bundle ID~~ **Resolved: Kadr** («кадр», Ukrainian for *frame/shot*; availability-checked 2026-08-27, no app collisions found). Bundle ID `app.kadr.Kadr`; register the GitHub org/repo and a domain (kadr.app or getkadr.app) before announcing.
2. gifski (AGPL) as bundled CLI vs pure-Swift GIF encoder quality tradeoff.
3. History storage format: flat files + SQLite index vs Core Data vs GRDB — proposal in doc 04 (§ persistence) is files + SQLite (GRDB).
4. Whether Phase 2 URL scheme mirrors CleanShot's verb names for drop-in Raycast compatibility, or defines its own with an alias layer.
5. Intel support end date.
