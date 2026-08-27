# Cross-Platform Evaluation — gpui / Rust vs Native Swift

> Can Kadr be built once in Rust with gpui (Zed's UI framework) and run on macOS, Linux, and Windows? Full evaluation as of August 2026, ending in a concrete recommendation.

---

## 1. gpui status (Aug 2026)

- **Published on crates.io since Oct 2025** (0.2.0; current 0.2.2, Oct 2025) under **Apache-2.0** — no longer git-only. But there has been **no crates.io release in ~10 months**, and serious consumers (e.g. gpui-component) still pin **git revisions of the Zed repo** because the published crate lags Zed's main branch. Practically, you live on a git dependency of a **pre-1.0 framework whose README promises breaking changes** and whose evolution is driven by Zed's needs.
- Relevant built-in feature flags: `screen-capture` (pulls in the `scap` crate — Zed uses it for call sharing), `wayland`, `x11`, `windows-manifest`, `macos-blade`.
- **Platform maturity:** macOS (Metal) — production-grade since 2023, by far the most mature. Linux (Vulkan via blade; X11 + Wayland) — GA since mid-2024 but with a long tail of compositor/GPU-driver issues in Zed's tracker (Hyprland/AMD window mapping, broken Wayland borders, slow resizes, 45 s startups on Intel iGPUs). Windows (DirectX) — **stable only since Oct 2025** ("Windows When? Windows Now"); launch criticisms: ~400 MB install, "Unsupported GPU" over Remote Desktop, weak Windows conventions (Alt-menus), no ARM64 at launch.
- **Docs:** gpui.rs + docs.rs exist with API coverage and ~14 examples, but conceptual docs are thin; the community's honest guidance remains "read Zed's source". Accessibility (screen readers) is a known hole.
- **Ecosystem is real now but small:** zed-industries curates an awesome-gpui list; highlights are gpui-component (Longbridge, ~12.5k★, 60+ components, powers a commercial trading app, macOS/Linux/Windows) and utilities like OpenLogi, ropy (clipboard manager), terminals. The original poster child Loungy is **no longer maintained**; its author's verdict stands: gpui felt "way smoother than the previous Tauri version" (no IPC/serialize hop), but he had to build his own text input and fight keycode/hotkey gaps.

**Verdict on the framework alone:** viable for a polished GPU-accelerated app on all three platforms, with editor-grade latency — at the price of git-dependency churn, learn-from-source documentation, minimal accessibility, and a support surface that includes GPU drivers.

## 2. What a screenshot app needs beyond UI — Rust crate reality

| Capability | macOS | Windows | Linux X11 | Linux Wayland | Assessment |
|---|---|---|---|---|---|
| Still capture | `scap` / `xcap` / `screencapturekit-rs` (SCK bindings) | `scap` / `xcap` / `windows-capture` (WGC) | `xcap` (trivial) | portals via `ashpd` → PipeWire; `scap` supports it | good crates exist; Wayland is portal-mediated with per-DE prompts |
| Recording + encode | AVAssetWriter via objc2, or ffmpeg | `windows-capture` has built-in MF `VideoEncoder` | ffmpeg/GStreamer | GStreamer `pipewiresrc` is canonical | three encode paths, or ship `ffmpeg-sidecar` (binary download, licensing sidestep) |
| Global hotkeys | `global-hotkey` (Carbon) ✅ | ✅ | ✅ | **✗ crate-level; portal `GlobalShortcuts` only** — GNOME 48+/KDE/Hyprland yes, **wlroots/sway no**; real apps fall back to "bind a CLI command in your compositor" | the weakest cross-platform link |
| Tray/menu bar | `tray-icon` (NSStatusItem) ✅ | ✅ | needs GTK loop thread or `ksni`; GNOME needs an extension | same | workable, awkward on Linux |
| Clipboard (image) | `arboard` ✅ | ✅ | ✅ | ✅ via wl-clipboard-rs feature; contents can die with process without a clipboard manager | fine |
| OCR | Vision via objc2 (best-in-class) | Windows.Media.Ocr (decent) | `ocrs` (beta) / Tesseract (mediocre on UI text) | same | **no cross-platform Vision equivalent** — 3 engines or degraded quality |
| Notifications | needs signed .app + UNUserNotificationCenter | AppUserModelID + toast | D-Bus ✅ | ✅ | fine once properly packaged |
| Selection overlay | gpui window at high level: OK | OK | OK | **needs `wlr-layer-shell` — gpui does NOT support layer-shell** (Zed only creates xdg-toplevels); on GNOME layer-shell doesn't exist at all → fake fullscreen toplevels | **structural gap for exactly this app's core interaction** |

## 3. The Wayland reality check (applies to ANY stack, not just gpui)

By design, a third-party Wayland client **cannot**: read screen pixels directly, register global hotkeys via a client protocol, enumerate other apps' window geometry, or place true always-on-top overlays without layer-shell (absent on GNOME). What it **can** do: one-shot screenshots via the Screenshot portal (GNOME wraps it in consent dialogs; Flameshot ships `flatpak permission-set` / dconf workarounds as official docs), recording via the ScreenCast portal → PipeWire (`restore_token` skips the picker on later runs), and promptless `wlr-screencopy` on sway/Hyprland/niri only. Every serious Linux screenshot tool maintains a per-compositor support matrix and documentation. **Linux support is therefore a product decision about tolerating portal UX, not a framework choice.**

## 4. Memory & performance comparison

No published idle-RSS figures exist for a minimal gpui app — the numbers below are the best available evidence, clearly labeled:

| Stack | Evidence | Expected idle RSS for this app |
|---|---|---|
| Swift/AppKit menu-bar agent | category norm; Shottr's whole 2.3 MB/17 ms brand | **15–40 MB** (our budget: <30) |
| gpui | Zed (full editor) idles ~200 MB; a tray utility is far smaller but keeps GPU pipelines/surfaces resident; Zed Windows install ~400 MB criticized | **~60–150 MB (estimate)** + GPU sensitivity (Remote Desktop, iGPU driver issues) |
| Tauri | 3-way 2026 benchmark: ~70 MB idle (WebView resident); Tauri's own tracker admits it can exceed Electron on WebKitGTK | 70 MB+ |
| Electron | same benchmark: ~300 MB | 250–400 MB |

gpui's genuine advantage over Tauri is **latency/smoothness** (no IPC serialization hop, GPU text/vector pipeline — Loungy's stated reason for leaving Tauri), not RAM. For an always-resident background agent, an idle AppKit status item costs essentially nothing while any GPU-rendered runtime does more per redraw. **The user's hard requirement — minimum RAM in background — is structurally easier to hit in Swift/AppKit than in any Rust GUI stack.**

## 5. Alternative Rust stacks (one paragraph each)

**Tauri v2** — best batteries for this category: official plugins for global shortcuts, tray, clipboard, autostart, updater; `scap` itself was built by a Tauri app (Cap). Costs: WebView UI (WebKitGTK jank on Linux), IPC latency for pixel-heavy annotation canvases, and a web-feeling UI that this category's users punish. The pragmatic choice if cross-platform mattered more than feel.

**Slint** — polished DSL, real accessibility, royalty-free desktop license, company-backed. Least natural for a freeform annotation canvas and capture overlays; still needs all the same capture/hotkey/tray crates.

**Iced** — powers System76's COSMIC desktop, *including COSMIC's own screenshot tool with layer-shell overlays* — proof the stack fits this domain on Linux. Pre-1.0 churn, accessibility/IME gaps. The best pick for a Linux-first sibling app.

**egui** — lowest-friction MVP (immediate mode, AccessKit); lowest polish ceiling ("tool-ish" look), continuous-repaint costs. Fine for internal tools, wrong for a CleanShot competitor.

## 6. Honest tradeoff analysis

**Dev velocity.** Swift-first: ScreenCaptureKit + Vision + AppKit + KeyboardShortcuts are first-party, stable, documented — a competent dev ships an MVP in weeks. gpui: three taxes at once — pre-1.0 git-dep framework, 6+ third-party system crates each with per-platform caveats, and the Wayland matrix. Realistic 2–4× effort to first release, before matching per-OS conventions.

**Polish ceiling.** Rendering/latency: gpui can match or beat (GPU pipeline, 2 ms-class input). macOS-native *feel*: mostly no at the margins — status-item behaviors, share sheets, Vision-quality OCR, native settings, VoiceOver, permission UX are each bridgeable via objc2, but then you're rewriting the Swift app in Rust with worse docs. Ceiling ≈ "95% as good, noticeably non-native in a dozen small ways" (Zed itself, beloved, still gets this criticism on Windows). And gpui's missing layer-shell makes the core selection overlay *worse* than native Linux tools on non-GNOME compositors.

**Maintenance.** gpui path = tracking Zed's refactors, triaging GPU-driver bugs (Zed's Linux tracker is the preview), 3 capture backends, 2–3 hotkey strategies, 3 OCR engines, per-compositor docs. That is a product team's burden, and the #1 OSS death cause in this category is maintainer burnout (ksnip). Swift path = one vendor's annual churn.

**Market.** Every tool users actually pay for in this category (CleanShot, Shottr, Xnapper, ShotBase, Screen Studio) is macOS-only — that's where the demanding users are. Linux already has strong free native answers per-desktop (GNOME Shell's tool, Spectacle, Flameshot, COSMIC); Windows has ShareX (free, enormous). **A cross-platform version doesn't fill an empty niche on those platforms the way it does on macOS.**

## 7. Recommendation

1. **Build macOS-first in native Swift** (docs 02–04). The user's two hard requirements — maximum performance and minimum background RAM — plus the polish bar set by CleanShot/ShotBase all point the same way, and the strongest OSS competitors (Snapzy, Capso, Mio) validate the stack.
2. **Hedge with architecture, not framework choice:** keep `AnnotationModel`, filename/template logic, and stitching math UI-free and side-effect-free (already the case in doc 04's layering). If cross-platform demand materializes post-Phase 3, extract those into a **Rust core (or keep Swift core + UniFFI is unnecessary — port the small pure parts)** consumed by native shells — the 1Password / Cap pattern: shared core, per-platform UI.
3. **If cross-platform ever becomes non-negotiable day-one** (it isn't, per the PRD): choose **Rust core + Tauri or per-platform shells**, not pure gpui — and accept portal-mediated UX on Wayland with CLI-bindable actions instead of global hotkeys on GNOME/sway. Re-evaluate gpui at 1.0: its trajectory is good (crates.io release, Windows stable, 12.5k★ component library), and it would then be the best-feeling Rust option.
4. **Do not** start in gpui today for this app: pre-1.0 churn on a git dep, no layer-shell for the core overlay, no OCR story, an estimated 2–4× slower path to the product that must win on macOS — all to serve platforms where free incumbents are already strong.

## 8. Key sources

crates.io/crates/gpui · gpui.rs · docs.rs/gpui · github.com/zed-industries/zed (gpui crate, Linux issue tracker: #15311, #37918, #44528, #58775) · zed.dev/blog/windows-when-windows-now · github.com/zed-industries/awesome-gpui · github.com/longbridge/gpui-component · github.com/MatthiasGrandl/Loungy + HN 39296505 · github.com/CapSoftware/scap · github.com/nashaofu/xcap · github.com/doom-fish/screencapturekit-rs · crates.io/crates/windows-capture · github.com/tauri-apps/global-hotkey (#28) · docs.rs/tray-icon (#336) · crates.io/crates/arboard · github.com/YaLTeR/wl-clipboard-rs · flameshot.org/docs/guide/wayland-help · flatpak.github.io/xdg-desktop-portal (GlobalShortcuts, Screenshot, ScreenCast) · discourse.gnome.org/t/screenshot-permissions/16935 · github.com/robertknight/ocrs · crates.io/crates/ffmpeg-sidecar · github.com/hoodie/notify-rust · boringcactus.com 2025 Rust GUI survey · pikvue.com Tauri/Electron/Neutralino 2026 benchmark (directional) · tech-insider.org Zed vs VS Code 2026 (directional).

> Reliability notes: the two benchmark sites are SEO-grade — treat numbers as directional. The boringcactus survey and Loungy thread predate gpui's crates.io release, so their "no docs/no crates.io" complaints are partially stale; the structural critiques (learn from Zed source, accessibility) still hold. The gpui idle-RSS figure is an inference, labeled as such — no published measurement exists.
