# Competitive Analysis — macOS Screen Capture Tools

> Part of the **Kadr** doc set (see `00-README.md` for the name and namespace).
> Research date: 2026-08-26. Prices and versions verified against vendor sites and changelogs on that date.

---

## 1. Why this document exists

The goal is a **free, open-source, native macOS screenshot app** that can credibly replace CleanShot X and ShotBase for most users. To do that we need to know, in detail: what those apps do, *how* their interactions work (the "feel" is the product), what users actually praise and complain about, and where the open-source field currently falls short.

**TL;DR of the whole analysis:**

1. CleanShot X wins on **workflow** (the post-capture Quick Access Overlay) and breadth (~50 features), not on any single capture trick.
2. ShotBase (launched Aug 2026) wins on **polish + library**: an AI-organized capture workspace and Screen-Studio-style auto-zoom recordings, at a steep $13–25/mo subscription.
3. Shottr proves that **performance is itself a feature**: 2.3 MB app, 17 ms capture, native Swift + AppKit after an abandoned Electron prototype.
4. The open-source field is split between non-native Qt tools (Flameshot, ksnip), a dormant Electron app (Kap), and young native Swift projects (Snapzy, Capso, ScreenCap, Mio) — none combines CleanShot-grade workflow, recording, permissive license, and signed/notarized distribution. **That combination is the open lane.**

---

## 2. CleanShot X — deep review

**Vendor:** MTW (Make The Web) · macOS 10.15+ · v4.8.10 (July 2026) · closed source, ~45 MB app.
**Pricing:** $29 one-time (perpetual license, 1 year of updates, 1 GB cloud) · Cloud Pro $8/user/mo annually for unlimited cloud + teams/SSO/custom domain · also in Setapp.

### 2.1 The core insight: the Quick Access Overlay

Every capture ends in a **floating thumbnail in the corner of the screen**. That thumbnail is the hub of the entire product:

- Drag it **directly into any app** (Slack, mail, Figma) — no file ever touches the Desktop.
- Click for actions: copy, save, annotate, upload (link auto-copied), pin.
- Swipe to dismiss; configurable position/size/auto-close; "restore recently closed overlay" undoes an accidental dismissal.
- Multiple captures stack in the overlay, enabling batch workflows.

Reviews consistently identify this overlay — not any capture mode — as the reason people can't leave CleanShot ("removing it makes workflows feel slower, messier, fragmented"). **Any serious alternative must nail this interaction first.**

### 2.2 Feature inventory (grouped)

**Capture modes**
- Area (custom region; exact-dimension typing; aspect-ratio lock; remembers last selection), Window (with choice of background behind the window: desktop / custom image / solid color / **transparent**; shadow toggle; since v4.8 the background is editable *after* capture), Fullscreen, Capture Previous Area (repeat last region), Self-Timer (delayed capture), All-In-One mode (one hotkey opens a single UI offering every mode).
- Precision aids: **crosshair mode**, **magnifier** (pixel zoom while selecting), **freeze screen** (pause live screen to capture moving content).
- **Scrolling capture** — vertical with optional auto-scroll, and horizontal since v4.8; works "across most applications".

**Recording**
- MP4 (H.264) or optimized GIF; quality/FPS/resolution controls.
- Mic + system audio simultaneously (v4.6 audio engine removed the need for an audio driver); auto Do-Not-Disturb; countdown; menu-bar timer.
- **Click visualization** (color/size/style), **keystroke overlay** (position/size, all keys or ⌘-combos only, light/dark), webcam overlay (position/size/shape, fullscreen camera mode), cursor show/hide.
- Built-in trim/resize/mute editor after recording.

**OCR** — "Capture Text": select a region → on-device text recognition → clipboard. Line-break options, QR-code reading, auto language detection, ~15 languages.

**Annotation editor**
- Tools: crop (aspect ratios, edge snapping), 4 arrow styles, shapes, line, **pixelate (with randomization "for security")**, blur, **spotlight** (dim all but focal area), **counter badges** (auto-numbered steps), smoothing pencil, highlighter incl. **Smart Highlighter** (auto word/line detection), text (7 styles), color picker.
- Multi-image composition (drag more screenshots into the canvas), **re-editable project file format**, rotate/flip, resize/downscale (Retina 2x→1x).

**Beautify** — background templates (20+), custom images, padding, **Auto Balance** (auto-centers/pads content), aspect presets, savable presets.

**Desktop hygiene** — hide desktop icons & widgets; temporary custom wallpaper during capture.

**Pinning** — float any screenshot above all windows; opacity/size control; arrow-key nudging; click-through "lock mode".

**History** — rolling one-month capture history with type filters and restore. (Notably *not* a full library — this is a gap ShotBase attacks.)

**Cloud** — optional one-click upload → short link; self-destruct/expiry, password protection, tags; Pro adds custom domain, teams, SSO/SCIM, searchable auto-transcribed video. ISO 27001.

**Automation** — a full **URL scheme API** (`cleanshot://capture-area?action=upload`, `capture-text`, `record-screen`, `pin?filepath=…`, `toggle-desktop-icons`, etc.) which makes it scriptable from Raycast/Alfred/Shortcuts; official Raycast integration.

### 2.3 What users say

Praise: the overlay workflow; all-in-one consolidation; scrolling capture; polished native UI; fully customizable shortcuts; fair $29 one-time price for the local feature set.

Complaints: cloud is where the subscription pain lives (~$317 over 3 years for Pro); feature bloat for casual users; **no pixel ruler/measurement tools** (sold separately as PixelSnap — a real gap developers/designers feel); no trial; occasional capture bugs on new macOS releases.

### 2.4 Performance posture

Marketed "performance-optimized native app"; reviewers report unproblematic RAM/CPU. But at ~45 MB it's the "heavy" option next to Shottr's 2.3 MB, and no public numbers exist. **An open-source app that publishes its idle RSS and capture latency as CI-tracked metrics can win credibility CleanShot never claims.**

---

## 3. ShotBase — deep review

**Vendor:** solo indie dev ("dudu", @dudufolio) · launched **v1.0.0 Aug 5, 2026**, v1.3.0 Aug 25, 2026 · distributed via GitHub releases + Sparkle · account-based (up to 3 devices).
**Pricing:** subscription only — **$25/mo, or $13/mo billed annually (~$156/yr)**. 7-day trial. No free tier, no one-time license.

### 3.1 Positioning: "a screen capture workspace"

ShotBase is not a utility; it's a **library-first workspace**. Its marketing explicitly targets people paying for CleanShot + Screen Studio + a share tool simultaneously ("cancelled three subscriptions"). Differentiators:

- **The Base (library):** every capture (screenshot, recording, web capture) lands in a single searchable library. **Local on-device AI** (Apple Silicon only; model downloaded during onboarding) auto-names captures, generates content tags, and writes short summaries; search runs across names + tags. Privacy pitch: image content never leaves the machine.
- **Recording with auto-zoom:** "record once, ShotBase follows the action" — automatic camera follow with smooth centered movement, plus "cinematic 3D" depth/perspective effects. This is Screen Studio territory, not CleanShot territory.
- **Web capture:** renders any URL **full-page or viewport, at chosen breakpoints (mobile/tablet/desktop), in light or dark mode** — i.e., real webpage rendering, not scroll-stitching. CleanShot has nothing comparable.
- **Unified editor** for stills *and* motion: backgrounds, frames, shadows, borders, watermarks, arrows, text, callouts, zoom guides.
- **Sharing:** explicit, manual (right-click → upload → link); never auto-uploads.
- **Craft as moat:** testimonials repeatedly cite the onboarding animations and trackpad haptic feedback. The lesson: in this category, micro-interactions market the product.

### 3.2 What ShotBase does *not* advertise

No mention anywhere of: OCR, GIF export, pinned screenshots, self-timer, hide-desktop-icons, webcam overlay, click/keystroke visualization, system-audio details, URL-scheme automation, link passwords/expiry, teams. As a 3-week-old product it is deep in a few areas and absent in many others.

### 3.3 Risks/objections (useful for our positioning)

$156–300/yr for a screenshot tool; account requirement; Apple-Silicon-only AI; single unproven developer; legal/pricing pages currently 404. Zero independent reviews exist yet — all sentiment is curated testimonials.

---

## 4. The performance benchmark: Shottr

Shottr (closed source, free + $12 license) is the existence proof for our performance goals:

- **2.3 MB** download; claimed **17 ms capture, ~165 ms to on-screen preview**.
- The author's Show HN comment is the key datapoint: *"The current version is Swift + AppKit. The first iteration was made on Electron, but then I changed my mind and rebuilt the project from scratch as a native app."*
- Feature-wise it owns the **developer/designer niche CleanShot ignores**: pixel ruler & measurements, color picker with OKLCH + APCA contrast, OCR + QR, pin, backdrops, object erase.
- Weaknesses: **no video recording at all**, no cloud/teams, closed source, small community.

Reputation summary from Reddit/HN: "uses almost no memory", "first thing I install on a new Mac". This is the reputation we want — with recording and an overlay workflow added.

---

## 5. Other alternatives (condensed profiles)

| App | Platform / stack | Price | Known for | Weakness |
|---|---|---|---|---|
| **macOS ⇧⌘5** | built-in | free | zero-install region/window/screen capture + basic .mov recording, timer, floating thumbnail → Markup | no scrolling capture, no OCR-in-flow, no GIF, no system audio, no history/library, no blur/redact, isolated files |
| **Xnapper** | macOS native | freemium, one-time | "beautify" niche: auto-balance backgrounds, social presets, **auto-redaction of emails/cards/API keys** | not a capture suite (no recording/scrolling) |
| **Snagit** | macOS+Win | $39/yr sub | best-in-class scrolling/panoramic capture; searchable library; step-tool docs workflows | 420 MB install, 150–250 MB RAM, helper CPU spikes, resented subscription switch, no GIF export |
| **Monosnap** | macOS+Win | free / $2.5–5/mo | quick capture + cloud integrations (S3/FTP/Drive) | account for cloud, shallow editor, no scrolling capture |
| **Droplr / Zight** | macOS+Win | ~$6–8/mo | SaaS share-links, team boards | everything behind subscription+account |
| **ScreenFloat 2** | macOS native | ~$7 one-time | floating reference shots; tagged shots browser; **non-destructive annotations**; data detectors | niche scope; LSUIElement discoverability issues |
| **Zappy** | macOS | free | fast capture + annotation, GIF; Zapier-funnel | cloud requires paid Zapier; slow development |
| **Screen Studio** | macOS | $89–229 | auto-zoom cinematic recordings — the recording quality bar | recording only |
| **Pika** | macOS, **MIT OSS** | free | color picker (OKLCH, WCAG) — reference code for eyedropper | single-purpose |

### Open source specifically

| Project | License | Stack | State (2026) | Takeaway for us |
|---|---|---|---|---|
| **Flameshot** (30.6k★) | GPLv3 | C++/Qt | active; Linux-first | great in-capture editor UX; on macOS: unsigned builds, Gatekeeper pain, non-native feel — the cautionary tale for cross-platform-first |
| **ksnip** (3.3k★) | GPL-3.0 | C++/Qt | maintainer seeking help | its **kImageAnnotator** shows a cleanly separated annotation library |
| **Kap** (19.3k★) | MIT | Electron | dormant since 2022 | loved UX, killed by Electron footprint + ScreenCaptureKit era; web-tech capture apps age badly |
| **Snapzy** (1.4k★) | **BSD-3** | Swift/SwiftUI + SCK + Vision + Sparkle, macOS 13+ | very active (v1.22, Jun 2026) | the most complete open CleanShot clone: scrolling capture, OCR, recording+keystrokes, GIF, redaction, S3/R2; study closely |
| **Capso** (1k★) | **BUSL 1.1** (not OSI-open until ~2029) | Swift 6, 12 SPM packages, macOS 15+ | active | best public *architecture* reference; license bars reuse in a competing app — read, don't copy |
| **ScreenCap** | MIT | Swift, 1 dependency, macOS 14+ | new | "zero network calls" privacy stance; minimal-dep blueprint |
| **QuickRecorder** (8.6k★) | AGPL-3.0 | SwiftUI + SCK | active | best OSS recording engine (driver-free system audio, HEVC-alpha, presenter overlay); AGPL → study only |
| **TRex** (1.8k★) | MIT | Swift + Vision | active | clean OCR/QR + URL-scheme/CLI patterns |
| **Azayaka** | GPL-family | Swift + SCK | active | small readable SCK recording code |
| **Mio** | OSS (Swift Forums showcase) | SwiftUI + SCK + actors | new | all-display freeze <80 ms; actor-based pipeline; vector-command annotation model |

---

## 6. Feature comparison matrix

Legend: ✅ yes · ⚠️ partial/gated · ❌ no

| Feature | ⇧⌘5 | CleanShot X | ShotBase | Shottr | Xnapper | Snagit | Flameshot | Snapzy (OSS) |
|---|---|---|---|---|---|---|---|---|
| Price | free | $29 (+$8/mo cloud) | $13–25/mo | free/$12 | freemium | $39/yr | free GPL | free BSD-3 |
| Native macOS (non-Qt/Electron) | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ❌ | ✅ |
| Region/window/full | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Scrolling capture | ❌ | ✅ (+horizontal) | ✅ | ✅ | ❌ | ✅ best | ❌ | ✅ |
| Post-capture overlay hub | ⚠️ thumbnail | ✅ signature | ⚠️ library instead | ⚠️ | ⚠️ | ❌ | ❌ | ⚠️ |
| Annotate | ⚠️ Markup | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Blur/pixelate + auto-redact | ❌ | ✅ / ❌ auto | ⚠️ | ✅ / ❌ | ✅ / ✅ **auto** | ✅ | ✅ | ✅ / ✅ |
| OCR in flow | ❌ | ✅ + QR | ❌ | ✅ + QR | ✅ | ✅ | ❌ | ✅ |
| Pixel ruler / measure | ❌ | ❌ | ❌ | ✅ | ❌ | ⚠️ | ❌ | ❌ |
| Color picker | ❌ | ⚠️ | ❌ | ✅ OKLCH/APCA | ❌ | ⚠️ | ⚠️ | ❌ |
| Pin/float screenshots | ❌ | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ⚠️ |
| Video recording | ✅ basic | ✅ | ✅ auto-zoom | ❌ | ❌ | ✅ | ❌ | ✅ |
| GIF export | ❌ | ✅ | ❌ | ⚠️ | ❌ | ❌ | ❌ | ✅ |
| System audio | ❌ | ✅ | ? | — | — | ✅ | — | ✅ |
| Webcam overlay | ❌ | ✅ | ? | — | — | ✅ | — | ⚠️ |
| Click/keystroke viz | ❌ | ✅ | ⚠️ zoom instead | — | — | ⚠️ | — | ✅ |
| History / library | ❌ | ⚠️ 1 month | ✅ AI library | ⚠️ recent | ✅ | ✅ | ⚠️ | ✅ |
| Search library by content | ❌ | ❌ | ✅ AI tags | ❌ | ❌ | ⚠️ | ❌ | ⚠️ |
| Cloud/link share | ❌ | ✅ ($) | ✅ | ⚠️ S3 BYO | ❌ | ✅ | ⚠️ Imgur | ✅ S3/R2 BYO |
| Backgrounds/beautify | ❌ | ✅ | ✅ | ✅ | ✅ core | ⚠️ | ❌ | ⚠️ |
| URL-scheme / CLI automation | ⚠️ `screencapture` | ✅ rich | ❌ | ⚠️ | ❌ | ⚠️ | ✅ CLI | ⚠️ |
| Footprint reputation | n/a | good (45 MB) | unknown (local AI model!) | **exceptional (2.3 MB)** | good | poor (420 MB) | Qt-heavy | good |

---

## 7. Market gaps → our opportunity

1. **The overlay workflow, open-sourced.** No OSS tool has a CleanShot-grade Quick Access Overlay (capture → floating thumbnail → drag anywhere, never touching the filesystem). It is the single most-praised interaction in the category and it is pure engineering, no services required.
2. **Performance as a credential.** Shottr markets "2 MB / 17 ms"; an OSS app can go further: publish idle-RSS and latency budgets, enforce them in CI, and make "auditable zero telemetry" a headline feature.
3. **Scrolling capture** is the hardest widely-demanded feature (absent from Flameshot/ksnip; immature in young OSS apps). Doing it reliably is a genuine moat.
4. **Recording polish under a permissive license.** QuickRecorder proves driver-free system audio + SCK recording works in OSS, but it's AGPL and recording-only. Nobody combines first-rate stills + recording + GIF under MIT/BSD/Apache.
5. **No-cloud sharing.** The $8/mo CleanShot Cloud is the #1 cost complaint, and every SaaS alternative (Droplr, Monosnap, ShotBase) gates sharing behind accounts. Our answer is the opposite extreme: **no upload features at all** — frictionless drag-and-drop file promises plus the native share sheet, with "zero networking code" as an auditable, marketable guarantee. (Product decision confirmed: local-only, DnD sharing — see PRD.)
6. **Sensitive-data auto-redaction** (Xnapper's email/card/API-key detection) is cheap with Vision + regex and aligns perfectly with an open-source privacy story.
7. **Developer/designer tooling** — pixel ruler, measurements, OKLCH/APCA color picker — costs little and buys evangelism from exactly the audience that adopts OSS tools (and that CleanShot ignores).
8. **OCR-indexed searchable history.** ShotBase charges $156/yr largely for an AI library; Vision OCR + on-device index gives 80% of that value for free, fully local.
9. **Trust infrastructure OSS tools skip:** Developer ID signing + notarization (Flameshot's #1 macOS complaint), Sparkle auto-updates, sane permission onboarding, localization.
10. **Table stakes** (must have, differentiates nothing): region/window/full capture, arrows/text/shapes, blur, clipboard-first flow, customizable hotkeys, OCR-to-clipboard.

## 8. Strategic conclusions feeding the PRD

- **macOS-first, native Swift.** Every winning product in this category is native and macOS-only; the two OSS cautionary tales (Qt feel, Electron rot) both stem from cross-platform-first choices. See `05-cross-platform-gpui.md` for the full gpui/Rust analysis and the recommended hedge (portable Rust core, later).
- **Differentiate on: overlay/DnD workflow + performance credential + zero-network guarantee + first-class editor + searchable local library.** Match on: capture modes, annotation, recording, OCR. Deliberately excluded: all sharing infrastructure (hosted or BYO), teams/SSO, web-rendering capture, cinematic 3D effects.
- **License: MIT or Apache-2.0** (not GPL) to maximize contribution and reuse; study-only list for AGPL/BUSL neighbors documented above.
- **Reference code:** Snapzy (BSD-3) as the broadest donor; TRex (MIT) for OCR; Pika (MIT) for color; Apple's CaptureSample for the engine; QuickRecorder/Capso as read-only references.

## 9. Sources

- CleanShot: cleanshot.com (/features, /changelog, /faq, /pricing, /product/cloud, /docs-api) · thesweetbits.com/tools/cleanshot-review · techradar.com/reviews/cleanshot-x-for-mac-review · screensnap.pro/blog/cleanshot-x-vs-shottr · g2.com/products/cleanshot-x/reviews · HN via hn.algolia.com
- ShotBase: shotbase.com (/download) · github.com/notnotDudu/shotbase-releases/releases · x.com/shotbaseapp · x.com/dudufolio
- Shottr: shottr.cc · news.ycombinator.com/item?id=28128673 (Show HN)
- Others: xnapper.com · monosnap.ai · zapier.com/zappy · macstories.net (ScreenFloat 2.0 review) · support.apple.com/en-us/102646 (⇧⌘5) · teenyapps.com/articles/cleanshot-x-alternatives · efficient.app/best/screenshot
- OSS repos: github.com/{flameshot-org/flameshot, ksnip/ksnip, wulkano/kap, duongductrong/Snapzy, lzhgus/Capso, 8tp/ScreenCap, lihaoyun6/QuickRecorder, Mnpn/Azayaka, amebalabs/TRex, superhighfives/pika, Brkgng/ScrollSnap} · Mio: forums.swift.org/t/87099

> Caveat: several comparison articles (screensnap.pro, teenyapps, lazyscreenshots, grabshot) are content marketing by competing apps — figures were cross-checked where possible but treat single-source numbers (e.g. Snagit RAM) as directional.
