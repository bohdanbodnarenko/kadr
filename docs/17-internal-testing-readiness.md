# Internal Testing Readiness Plan

> Written 2026-09-24 against `main` @ `4b73b57`: about 94k lines, 16 packages, 4 app targets and
> about 2,750 tests. This plan answers one question: **what has to change before a small group of
> dogfooders can install a signed Kadr, use it every day, and report what goes wrong in a way we
> can act on?**
>
> `03-features.md` stays authoritative for behaviour, `04-swift-architecture.md` for structure and
> `CLAUDE.md` for the hard rules. This document supersedes the ordering of docs 14 and 16 for the
> work left before internal testing. Their IDs are kept wherever an item is theirs.
> `12-release-checklist.md` stays the per-release human script; §8 adds rows to it.

## 0. Verdict

**Not ready yet. The gap is about three weeks for one engineer, and most of it is small.**

The core is in much better shape than the earlier reviews suggest:
- Most of docs/11 S0–S2, docs/13 T0–T2 and docs/16 P0–P1 really landed:
  - export integrity;
  - the recording-lifecycle races;
  - the telemetry seam;
  - VFR export;
  - source-time zoom cues;
  - the mic track;
  - Tidy review;
  - card Save on failure;
  - editor saves reaching the card and History.
- Lint, the layering, zero-network and SCK-only gates, and 15 of 16 package suites are green.
- There are no `try!`, no force unwraps and no stray `print`. Signposts cover every PRD §8 budget.
- Hardened runtime is on for every target, and the entitlements are minimal.

Three kinds of problem stand between that and a tester:

1. **No tester can receive a build, or an update to one** (§3, Wave 0).
   - No Developer ID certificate has ever been used.
   - `release.sh` removes the camera and microphone entitlements and leaves nested code unsigned.
   - The Sparkle feed URL never reaches the built Info.plist.
   - Every build calls itself "1.0 (1)".
   - The app test suite has not actually run since 2026-09-18, and CI still reports it green.
2. **A handful of ordinary actions lose work** (§3, Wave 1).
   - ⌫ typed into another app while the pointer rests on a card deletes the capture.
   - Pause/Resume writes the paused time back into the movie as a frozen frame.
   - Saving an annotated capture never updates the file it came from.
   - The studio can hand back a stale render as a fresh export.
   - Changing History retention permanently deletes captures with no confirmation.
3. **Testers could not tell us.** There is no crash capture, no diagnostics export, no "Report a
   Problem", no symbol files kept, and no build identity. The first week of dogfooding would
   produce reports that say "it didn't work" with nothing attached.

Wave 0 (distribution plus the feedback loop) and Wave 1 (data loss plus day-one breakage) are the
entry criteria for internal testing. Wave 2 runs during dogfooding. Wave 3 is the gate to an
external beta.

---

## 1. How this was produced

**Method:**
- Seven parallel reviews each read one area in full against docs/03 and the open items of
  docs/11, 13, 14 and 16. The areas were: the app shell and first run; capture; after capture
  (cards, pins, History, automation); recording; the annotation editor; the studio and export;
  and release readiness.
- The release review also ran every gate on this machine (macOS 27.0, Xcode 27.0, Swift 6.4).
- Every Blocker and most High findings were then re-checked by hand against the code while this
  document was written. Those carry **✔ verified** below.
- Items marked **[device]** can't be settled by reading. They are collected in §8.

**Limits:**
- No reviewer ran Kadr interactively. What docs/12 says still holds: the real-device pass is the
  biggest remaining unknown.
- Nothing here was measured on hardware other than the gates in §2.

### Severity

| Level | Meaning | Rule |
|---|---|---|
| **P0** | Blocks internal testing. The build can't be installed or updated, a user action loses work, a primary flow is broken on day one, or testers can't report a problem. | Fix before the first dogfood build. |
| **P1** | A tester will hit it in the first week and file it. It is noise that hides real reports. | Fix during dogfood week 1–2, or list it in Known Issues. |
| **P2** | Polish, HIG conformance, accessibility depth, edge cases. | Fix before an external beta. |
| **P3** | Spec depth and nice-to-have items. | Backlog. |

Effort: **S** ≤ ½ day · **M** 1–3 days · **L** > 3 days.

---

## 2. Gate results (2026-09-24, clean `main`)

| Gate | Result | Notes |
|---|---|---|
| `make build` / `make build-editor` | ✅ pass | Only warning: "multiple matching destinations". |
| `make lint` | ✅ pass | 0 SwiftLint violations, 0 SwiftFormat changes. **SwiftLint doesn't cover `KadrEditor/`, `HelperTools/` or `KadrCLI/`** (`.swiftlint.yml` `included:`). |
| `make check` | ✅ pass, but on **stale products** | `check-size` measured the 2026-08-30 archive (12 MB, 2.1 MB to spare). The linkage check read a 2026-09-21 Release build. |
| Package tests | ⚠️ 15/16 pass | **VisionServices: 2/37 fail on macOS 27.** OCR joins lines (`TextRecognizerTests.swift:128`), and the redaction scanner misses the card number, JWT and AWS key (`RedactionCandidateTests.swift:92,98`). This is likely an OS OCR drift. CI runs macOS 26. |
| `make test-app` | ❌ **the runner crashes before any test; exit status 0** | `ShortcutDefaultsMigrationTests` (`KadrTests/StatusMenuLayoutTests.swift:184`, added 2026-09-18) passes `KeyboardShortcuts.Shortcut` values as `arguments:`. swift-testing describes them off the main thread and trips `dispatch_assert_queue`. The Makefile ends the pipe in `\|\| true` (`Makefile:102`), so CI is green. With that suite skipped: 432 tests, 3 failures. Two are known (`PinPanelTests.keepsAspectRatio`, `PointerSeamTests.disabledTapDropsARung`). One is new: `VisionClientTests` times out, probably because the XPC helper is unsigned. |
| `make perf`, `make size-gate` | not run | They kill running Kadr instances or do a fresh archive. Run them in Wave 0 on a clean machine. |

---

## 3. The plan

### Wave 0: make a build a tester can install, update and report from (≈ 4–5 days)

**Exit:** a notarized DMG installs on a clean Mac. Sparkle offers the next build. A tester can press Help ▸
Report a Problem… and attach a diagnostics zip, and we can symbolicate the crash it contains.

| ID | Item | Sev | Effort |
|---|---|---|---|
| T-REL-1 | Developer ID certificate and notary profile | P0 | S |
| T-REL-2 | Sparkle keys into the real Info.plist ✔ | P0 | S |
| T-REL-3 | Replace hand re-signing with `-exportArchive` ✔ | P0 | M |
| T-REL-4 | Public feed host, and a beta channel | P0 | S |
| T-REL-5 | Build identity: monotonic build number plus git SHA | P0 | S |
| T-REL-6 | Keep dSYMs and archives per build | P0 | S |
| T-REL-7 | Unmask and fix the app test suite ✔ | P0 | S |
| T-DIAG-1 | Help ▸ Report a Problem… and Export Diagnostics… | P0 | M |
| T-DIAG-2 | Local crash and hang capture (MetricKit) | P1 | M |
| T-DIAG-3 | Persist the logs that matter | P1 | S |
| T-DIAG-4 | Tester guide, known issues and clean-slate uninstall | P0 | S |

### Wave 1: stop losing work and fix what breaks on day one (≈ 8–10 days)

**Exit:** no known path loses a capture, a recording, an edit or typed text. Every primary flow in docs/15's
"keyboard flows that must complete" works by pointer. §7's smoke script passes on one Retina and one
dual-display setup.

This wave holds every P0 in §4 not already listed in Wave 0. In order:

1. **Data loss:**
   - T-OUT-1 (hover ⌫)
   - T-REC-1 (pause gap)
   - T-ED-1 (save/reopen)
   - T-STU-1 and T-STU-2 (stale export)
   - T-OUT-4 (retention wipes)
   - T-OUT-3 (Ask-where-to-save loses capture)
   - T-OUT-5 (Save on library cards)
   - T-OUT-6 (silent export failure)
   - T-ED-4 (Esc discards typed text)
2. **Phantom states:** T-REC-2, T-REC-3, T-REC-8.
3. **Dead controls:**
   - T-SH-1 (agent menu)
   - T-ED-2 (editor Window menu)
   - T-CAP-1 (colour pick click)
   - T-OUT-2 (banner can't be clicked)
   - T-REC-5 (DND toggle)
4. **Focus theft on the main entry point:** T-CAP-3.

### Wave 2: dogfood weeks 1–2 (≈ 2 weeks, in parallel with testing)

All P1 in §4, ordered by what testers report. Expect to reorder this wave after the first week of reports.

### Wave 3: gate to external beta (≈ 3–4 weeks)

- All P2.
- The accessibility pass (docs/15's Inspector audits for all 11 surfaces).
- The docs/12 device matrix.
- Localization plumbing for packages.
- The URL-scheme consent model if it slipped from Wave 2.
- A PrivacyInfo manifest.

---

## 4. Findings and fixes, by area

Each entry gives the evidence (file:line), the fix, and where relevant the Apple guidance it follows.

### 4.1 Release, distribution and trust (T-REL)

**T-REL-1 · No Developer ID identity has ever been used · P0 · S**

`security find-identity` lists only "Apple Development". There is no notarytool profile, no git tag, the
appcast has no items, and the cask is at `0.0.0`.

**Fix:**
- Create a *Developer ID Application* certificate; this needs the Account Holder role.
- Run `xcrun notarytool store-credentials kadr-notary` with an App Store Connect API key, not an app-specific password, so CI can use it later.
- Tell testers once that moving from `make install` (development-signed) builds to Developer ID builds changes the designated requirement. Screen Recording, Accessibility and Input Monitoring will each ask **one more time**.
- Ref: *Notarizing macOS software before distribution*; *Developer ID*.

**T-REL-2 · Sparkle's keys are dropped by the Info.plist generator · P0 · S · ✔ verified**

**Evidence:**
- `INFOPLIST_KEY_SUFeedURL` and `INFOPLIST_KEY_SUEnableInstallerLauncherService` are set at `project.pbxproj:721-722,759-760`.
- Xcode emits only the `INFOPLIST_KEY_` names it recognises, and `PlistBuddy -c "Print :SUFeedURL"` on the built app says *Does Not Exist*.
- `SUPublicEDKey` is absent everywhere, and `RELEASING.md` suggests adding it the same broken way.
- `release.sh:66` checks a `Kadr/Info.plist` that doesn't exist, so the preflight can never fail.

**Fix:**
- Move `SUFeedURL` and `SUPublicEDKey` into `Config/Kadr-Info.plist`.
- Delete `SUEnableInstallerLauncherService`, which is only needed when sandboxed.
- Add a KadrTests assertion that both keys are non-empty in `Bundle.main`.
- Make `release.sh` read the key from the archived app and exit non-zero if it is missing.
- Generate the EdDSA pair with Sparkle's `generate_keys`, keep the private key in the login keychain, and record where it lives in `RELEASING.md`.
- Without the key, Sparkle 2.9 falls back to code-signing-only validation, which it logs as deprecated.

**T-REL-3 · `release.sh` can't produce a working notarized app · P0 · M · ✔ verified**

**Evidence:**
- `release.sh:101,104` re-signs with `codesign --force` and no `--entitlements`, which **removes `device.camera` and `device.audio-input`**. The hardened runtime then silently denies camera and mic.
- The nested loop only walks one level deep, so these keep their development signatures and notarization rejects them:
  - `Contents/Helpers/kadr`
  - `KadrEditor.app/Contents/XPCServices/HelperTools.xpc`
  - Sparkle's `Autoupdate`, `Updater.app`, `Downloader.xpc` and `Installer.xpc`
- When `sign_update` is missing, the script skips the appcast and still prints "Done".
- dSYMs are thrown away.
- `Distribution/kadr.rb` is never updated, although its comment says it is.

**Fix:**
- Use `xcodebuild -exportArchive` with an `ExportOptions.plist` of `method = developer-id`, `signingStyle = automatic` and `teamID`. This re-signs nested code inside-out and keeps each target's entitlements.
- Then gate on all of these:
  - `codesign -d --entitlements - Kadr.app` contains camera and audio-input;
  - `codesign --verify --deep --strict`;
  - `spctl -a -vvv -t exec`;
  - `xcrun stapler validate`.
- On a notarization failure, print `notarytool log <id>`.
- Make every missing tool a hard failure.
- Add a `make dmg` target so the release path follows the same one-definition rule as the other commands (see CLAUDE.md, "Commands").
- Ref: *Distributing software outside the Mac App Store*; Sparkle's *Sandboxing and code signing* order if manual signing is ever kept.

**T-REL-4 · The feed host is unverified, and there is no beta channel · P0 · S**

**Evidence:**
- `SUFeedURL` points at `raw.githubusercontent.com/kadr-app/kadr/main/appcast.xml`, but `git remote -v` is empty. A private repository's raw URL returns 404.
- `UpdaterManager` passes `updaterDelegate: nil` (`UpdaterManager.swift:145-149`).

**Fix:**
- Host the appcast and DMGs somewhere public and static: GitHub Pages, or a public releases repository.
- Add an `SPUUpdaterDelegate` whose `allowedChannels(for:)` returns `["beta"]` when Settings ▸ Updates ▸ "Receive beta builds" is on. It should be on by default for dogfood builds.
- Make `update-appcast.sh --channel beta` emit `<sparkle:channel>beta</sparkle:channel>`.
- Add `<sparkle:releaseNotesLink>` from a `CHANGELOG.md` section.
- Implement `SPUStandardUserDriverDelegate.supportsGentleScheduledUpdateReminders` so an update alert from an LSUIElement app doesn't appear behind other windows. Wrap Sparkle's show/dismiss callbacks in `ActivationJuggler.beginRegularWindow` / `endRegularWindow` instead of the 120 s backstop (`UpdaterManager.swift:37,76-86`).
- Add *Check for Updates…* to the agent's app menu (APP-3).

**T-REL-5 · Every build is "1.0 (1)" · P0 · S**

**Evidence:**
- `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` are hard-coded on every target.
- Sparkle needs a `CFBundleVersion` that only ever increases.

**Fix:**
- Stamp `CURRENT_PROJECT_VERSION` from `git rev-list --count HEAD` in the Makefile and the release script. Refuse a build number ≤ the newest `<sparkle:version>` in the appcast.
- Add a custom `KadrGitCommit` Info key.
- Set `MARKETING_VERSION = 0.9.0` for dogfood builds and tag `v0.9.0-b<build>`.
- Show "0.9.0 (512 · abc1234)" with a **Copy** button in Settings ▸ Updates ▸ About and in the About panel's `credits`/version.

**T-REL-6 · dSYMs and archives are not retained · P0 · S**

Tester `.ips` reports can't be symbolicated without them.

**Fix:**
- Keep the `.xcarchive` (or `dSYMs/`) under `dist/symbols/<version>-<build>/`, with `dwarfdump --uuid` output.
- Add `dist/` to `.gitignore`.
- Symbolicate with `atos`, or by importing the archive into the Organizer.

**T-REL-7 · The app test suite doesn't run, and CI hides it · P0 · S · ✔ verified**

See §2.

**Fix:**
- Pass raw key and modifier values as `arguments:` and build the `Shortcut` inside the `@MainActor` test body.
- Make `test-app` fail properly: `set -o pipefail` and drop `|| true`, or read the result from the `.xcresult`.
- Then triage `VisionClientTests` (tag it `.enabled(if:)` signed-only if it needs a signed helper) and the two known failures.
- Update the memory note: `OverlayEngagementTests` now passes.

**T-REL-8 · Other release hygiene · P1 · S**

- **Repository clean-up:**
  - `git rm _to_delete/` (tracked `screendrop-src.tgz`, `screendrop2.tgz` and three Kadr tarballs). Purge it from history before the repository is shared, because docs/08 flags licence caution on Screendrop's tldraw-derived code.
  - Ignore `.cursor/hooks/state/`.
- **Build setup:**
  - Share the `KadrEditor` scheme; a fresh CI clone doesn't have it.
  - Add `KadrEditor/`, `HelperTools/` and `KadrCLI/` to SwiftLint.
  - Make `check-size` and the linkage check fail when the product is older than `HEAD`, or build first.
- **Info.plist:**
  - Remove the dead `INFOPLIST_KEY_NSScreenCaptureUsageDescription` and its test assertion.
  - Add `LSApplicationCategoryType = public.app-category.productivity`.
- **Homebrew cask:** complete the `zap` list (`app.kadr.Kadr.Editor` prefs, `HTTPStorages`, Saved Application State).
- **Repository documents:**
  - `README.md` still says "pre-alpha, M0 done". Refresh it.
  - Add `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md` and `.github/ISSUE_TEMPLATE/bug.yml`.
- **VisionServices on macOS 27:**
  - Confirm the failures on the macOS 26 CI runner.
  - If this is OS drift, make `SecretScanner` tolerate OCR noise (trailing glyphs, `l`/`|`/`1` confusion) and keep golden images per OS.
  - An auto-redaction that silently misses a card number is a privacy defect, not a test flake.

**T-REL-9 · PrivacyInfo.xcprivacy · P2 · S**

**Evidence:** no target has a privacy manifest. The code uses these required-reason APIs:
- UserDefaults, in 23 files;
- file timestamps;
- disk space (`SpeechModelInstaller`);
- `systemUptime`.

**Fix:** a manifest isn't required outside the Mac App Store, but it is Apple's recommended practice and cheap. Add one to Kadr and KadrEditor with reasons CA92.1, C617.1, E174.1 and 35F9.1. Ref: *Describing use of required reason API*.

### 4.2 Diagnostics and the feedback loop (T-DIAG)

Every item here is local and user-initiated. None of them adds networking, so rule 1 holds.

Opening a URL in the user's browser through `NSWorkspace.open` is already done for OCR links (`TextCaptureToast.swift:156`) and doesn't trip `check-layering.sh`. **State it in CLAUDE.md rule 1**, so a "Report a Problem" link is never read as a third network exception: the app sends nothing; the browser opens a page.

**T-DIAG-1 · Report a Problem… and Export Diagnostics… · P0 · M**

**Evidence:**
- None of this exists. The Help menu has only Kadr Help and Keyboard Shortcuts, and both are dead (T-SH-1).
- The Debug menu is `#if DEBUG` only, so it isn't in tester builds.

**Fix:** add **Help ▸ Export Diagnostics…**, also in the status-item menu under ⌥. It builds a zip with `/usr/bin/ditto -c -k` and reveals it in Finder. The zip contains:
- `OSLogStore(scope: .currentProcessIdentifier)` entries for subsystem `app.kadr.Kadr` over the last 24 h. Use `OSLogStore.local()` when permitted; otherwise tell the tester to run `sudo log collect`.
- `~/Library/Logs/DiagnosticReports/{Kadr,KadrEditor,HelperTools}*.ips`.
- MetricKit payloads (T-DIAG-2).
- A `system.json` with:
  - version, build and SHA;
  - macOS build, hardware model, CPU architecture;
  - displays (count, scale, arrangement, notch);
  - each TCC status from `AppPermissionTracker`;
  - `HotkeyHealth.conflicts`;
  - login-item state;
  - the running path (translocated or DMG?);
  - non-default settings with paths redacted to `~`;
  - free disk space, studio-session count and total size, and History row count.

Add **Help ▸ Report a Problem…**:
- It runs Export Diagnostics, then opens a prefilled GitHub issue-form URL (`/issues/new?template=bug.yml&version=…&build=…&os=…`). Only non-identifying fields go in the URL; the zip is attached by hand.
- Use a `mailto:` fallback if the repository is private.
- Put **Copy Diagnostic Summary** (the `system.json` as text) next to the version in Settings ▸ Updates.

**T-DIAG-2 · Crash and hang capture · P1 · M**

There is no MetricKit anywhere.

**Fix:**
- Register an `MXMetricManagerSubscriber` in the agent and the editor (macOS 12+).
- Write `didReceive` payloads for `MXDiagnosticPayload` (crashes, hangs, CPU and disk-write exceptions) and `MXMetricPayload` as JSON to `~/Library/Application Support/Kadr/Diagnostics/`. Cap it at 30 files.
- No timer is involved (rule 2): the OS delivers payloads at most daily.
- The hang diagnostics directly test the PRD's "zero main-thread stalls" posture.

**T-DIAG-3 · Logs that survive until someone asks · P1 · S**

**Evidence:**
- Production code has 142 `.info` calls, 120 `.error`, 5 `.debug` and **0 `.notice`**. Info isn't persisted by default, so `log show` after the fact has lost most of the story.
- There are 179 `privacy: .public` annotations and 0 `.private`, and user file names are logged in the clear (e.g. `EditorAppDelegate.swift:245`, `CaptureImporter.swift:56`).

**Fix:**
- Promote lifecycle events to `.notice`: capture start/finish, record start/pause/stop, export start/finish/fail, update check, permission change, and launch with version.
- Log file names as `.private(mask: .hash)`.
- Optionally, for dogfood builds only, add `OSLogPreferences` for `app.kadr.Kadr` with `Persist: Info` (`man 5 os_log`).
- Fix the geometry probe predicate: docs/12 and `RecordingEngine+StreamOutput.swift:146` say `subsystem == "app.kadr"`, but the real subsystem is `app.kadr.Kadr`.
- Make the probe a runtime toggle (Settings ▸ Advanced ▸ Diagnostics) instead of `#if DEBUG`. Otherwise no dogfooder can ever answer docs/12 §6.

**T-DIAG-4 · Tester onboarding and a clean slate · P0 · S**

**Fix:**
- Add `TESTING.md`, covering:
  - installing from the DMG and **moving the app to /Applications before the first launch**;
  - the TCC grants and why each is needed;
  - the macOS 15+ monthly Screen Recording re-confirmation;
  - how to Report a Problem;
  - what "a good report" contains;
  - the Known Issues list (seeded from every P1 not fixed at build time).
- Add a `Scripts/uninstall.sh` for repro resets. It should:
  - run `defaults delete` for both bundle IDs;
  - remove `~/Library/Application Support/Kadr`;
  - run `tccutil reset` for ScreenCapture, Accessibility, ListenEvent, Microphone, Camera and SpeechRecognition;
  - unregister the login item;
  - remove the CLI link;
  - restore `com.apple.finder CreateDesktop`.
- Add Settings ▸ Advanced ▸ **Remove All Kadr Data…**, next to Reset All Settings, with a destructive confirmation.
- Store `lastLaunchedBuild` and log upgrade transitions. This is also the hook for a later "What's New".

### 4.3 App shell, first run, settings (T-SH)

**T-SH-1 · Agent menu: Settings…, Kadr Help, Keyboard Shortcuts and Hide Sidebar are dead · P0 · S · ✔ verified**

**Evidence:**
- `AppMenu.swift:83-87,153-175` adds items with `addItem(withTitle:action:keyEquivalent:)` and no target.
- The selectors exist only on `AppMenu`, an `NSObject` outside the responder chain.
- `AppDelegate.openSettings()` takes no sender, so nothing responds.
- Result: whenever Settings, History, Help or onboarding is frontmost, ⌘, and ⌘? are greyed out, and **the Help window can't be opened from anywhere**.

**Fix:**
- Set `item.target = self`.
- Add a KadrTests walk of `NSApp.mainMenu` asserting that every item has a target or a responder.

**T-SH-2 · Run from the DMG or a translocated path · P1 · M**

**Evidence:** nothing checks where the app is running from. Running from `/Volumes/…` or `AppTranslocation` breaks:
- the login item;
- Sparkle's in-place update;
- the CLI symlink;
- the TCC grants, which attach to a path that later changes.

**Fix:** at launch, if `Bundle.main.bundlePath` is under `/Volumes/` or contains `AppTranslocation`, offer *Move to Applications and Relaunch*. Implement it in house (LetsMove-style); it is a small amount of code.

**T-SH-3 · Relaunch after the first grant: the new instance loses the CLI port, and no single-instance guard exists · P1 · S–M**

**Evidence:**
- `RelaunchHelper.swift:56-60` launches the new instance *before* the old one quits.
- The new `AutomationListener.start()` fails because the port name is taken, and it never retries (`AppDelegate.swift:360-371`).
- `kadr` CLI commands therefore fail until the next manual relaunch.
- There is no `NSRunningApplication` check, so a DMG copy and an /Applications copy (or a dev and a release build) can run side by side with doubled hotkeys.

**Fix:**
- Stop the listener and unregister hotkeys before `openApplication`.
- Add a launch-time guard that activates the running copy and exits.

**T-SH-4 · Onboarding copy and entry points · P1 · S**

- **Stale menu reference:** `OnboardingView.swift:58-61` tells users to choose "Setup & Permissions". The item is now **Finish Setup…**, and it is reached by **right-click**, because a left-click opens the island. Drive the title from a shared constant.
- **Finish Setup restarts from the beginning:** Finish Setup… reopens Welcome and re-arms every coach tip (`AppDelegate+Commands.swift:261-268`). Open directly at Permissions, and keep "Replay Welcome" separate.
- **First-run double dialog [device]:** `ensureAccess` fires `CGRequestScreenCaptureAccess()`, and then `allowCapture` shows Kadr's own modal alert on top (`ScreenRecordingPermission.swift:145-155`, `PermissionRecovery.swift:71-81`). Skip Kadr's alert when the system prompt was issued in the same call.
- **The Permissions pane is missing a restart and a row:**
  - Settings ▸ Permissions has no **Quit & Reopen Kadr** button when a grant that needs a relaunch flips to allowed (`PermissionsPane.swift:5` builds the tracker without a coordinator).
  - Speech Recognition isn't listed, and a denied Speech permission silently degrades the teleprompter (`TeleprompterController.swift:158-167`).
- **Desktop access prompt [device]:** the default save folder is `~/Desktop` (`AppSettings+Parity.swift:71-74`), so the first save raises an unexplained "access files in your Desktop folder" prompt. Either default to `~/Pictures/Kadr` (created on demand), or choose the folder through `NSOpenPanel` in onboarding, which grants access by user intent.

**T-SH-5 · Reopen and bring-forward (APP-1 flaw, APP-4 open) · P1 · S**

**Evidence:**
- A Dock click while History or Settings is open pops the status menu, because `applicationShouldHandleReopen` ignores `hasVisibleWindows` (`AppDelegate.swift:465-474`).
- When a window already exists, `show()` calls only `makeKeyAndOrderFront`, with no activation and no deminiaturize:
  - `SettingsWindowController.swift:90-93`
  - `OnboardingWindowController.swift:39-42`
  - `HistoryWindowController.swift:41-43`
  - `KadrHelpWindow.swift:14-17`, which also ignores the requested topic

**Fix:** add one `ActivationJuggler.bringForward(_:)` and use it everywhere.

**T-SH-6 · Destructive menu actions and alerts · P1 · S**

- **No confirmation on menu actions:** status menu *Discard Recording* and *Restart Recording* act in one click (`StatusItemController.swift:237-251`).
  - Confirm with an `NSAlert` whose destructive button has `hasDestructiveAction = true`, or confirm only when the take is longer than 10 s.
  - Move Discard into its own group.
- **Quit alerts:**
  - *Discard and Quit* isn't marked destructive (`AppDelegate+Termination.swift:114-116`).
  - The comment at `:88` wrongly says Cancel is leftmost.
  - The editor's *Quit Anyway* is the Return default during an export (`EditorAppDelegate.swift:178-180`); make *Keep Exporting* the default.
- **Overlay toggle items:** Hide/Show Overlays and Hide/Show Pins change the title *and* show a checkmark (`StatusItemController+Overlay.swift:30-31,48-49`). Do one or the other (HIG › Menus › toggled items).
- **Reference:** HIG › Alerts.

**T-SH-7 · Hotkey health is probed and then ignored (X-2 partial) · P1 · S**

**Evidence:**
- `HotkeyHealth.conflicts` has no reader.
- A default like ⇧⌘2 or ⌃⇧4 held by another app fails silently, which is the most likely first-run complaint.

**Fix:**
- Show a warning glyph on the Shortcuts sidebar row and an inline `ControlInlineStatus` on the failing recorder.
- Re-probe after a change, and list conflicts in diagnostics.
- Disable *Restore Default* when the shortcut already has its default value.
- **[device]**: check whether Carbon registration reports hotkeys held by other processes on 15 and 26. If not, detect conflicts by "pressed but not received" instead.

**T-SH-8 · Settings correctness · P2 · S**

- **Reset All Settings doesn't re-apply live state** (`AdvancedPane.swift:75-78`). Specifically:
  - a hidden status item isn't shown again;
  - `CaptureVisibility.includesOverlays` isn't refreshed;
  - hidden desktop icons aren't restored (`DesktopHygiene.swift:150-163`).
- **Settings always opens on General** (`SettingsWindowController.swift:95`). Restore the last pane, as HIG › Settings asks. Sidebar visibility isn't persisted either, although the comment at `SettingsView.swift:32-36` says it is.
- **Captions under the wrong control:** the sRGB caption follows the capture-sound toggle (`GeneralPane.swift:100-110`), and the Do Not Disturb section footer talks about overlays (`RecordingPane.swift:208-212`).
- **Wrong or unhelpful copy:**
  - AdvancedPane says "See docs/AUTOMATION.md", which is not a path users can open. Link to the online docs, or show a Help topic.
  - CLI Remove reports "Nothing to remove." when removal *failed* (`CLIInstaller.swift:79-90`); give it an outcome enum (APP-7).
  - Check Now is disabled in Debug builds with no explanation.
- **`UpdatesPane`** reads `automaticallyChecksForUpdates`, which is computed from `UserDefaults` and so isn't tracked by `@Observable` (APP-P1).
- **`kadrLayoutDirection()` forces LTR** unless `-KadrRTL` is set (`AccessibilityChrome.swift:129-131`). Only override when the flag is present.
- **Studio storage section:** `StudioStorageSection` scans sessions synchronously on the main actor, and `try? session.delete()` swallows failures (`:65-80`).

**T-SH-9 · Help content · P2 · M**

**Evidence:**
- Eight thin topics, with default shortcuts hard-coded (`KadrHelp.swift:75-84`) that go stale as soon as the user rebinds them.
- No troubleshooting.
- The keystroke-overlay copy omits Input Monitoring (`RecordingOverlaySource.swift:253-260`).

**Fix:**
- Render shortcuts from `KeyboardShortcuts.getShortcut`.
- Add these topics:
  - *Nothing happens when I press the shortcut*
  - *Permissions*
  - *Where are my files?*
  - *Reporting a problem*
- Set `NSApp.helpMenu` in both apps so the Help menu gets its search field.

### 4.4 Capture (T-CAP)

Rules 3, 4, 6 and 8 all pass in this area. NotchCrop (CAP-1), the quality slider (CAP-9) and the ⌘ child-window pick are done.

**T-CAP-1 · Colour pick can't pick with a click · P0 · S · ✔ verified**

**Evidence:**
- The hint says "Click to copy" (`HintLayerGroup.swift:90`), but nothing in the mouse path checks `isEyedropperMode`.
- A click without a drag falls back to idle (`SelectionInteraction.swift:155-160`).
- A small drag takes a region *screenshot* (`SelectionOverlayView.swift:277-342`).
- Only Return picks, and on more than one display Return usually reaches the wrong panel (T-CAP-2).

**Fix:** in `mouseUp`, when in eyedropper mode, call `onPickColor(currentPick)`, and ignore drags.

**T-CAP-2 · Keyboard goes to the last-created display's panel, not the one under the pointer · P1 · S**

**Evidence:**
- `present(on:)` calls `makeKey()` on every panel, so the last one wins (`SelectionOverlayController.swift:124-129`).
- `onBecameActive` never makes the panel under the pointer key (`:409-414`).

**What breaks before the first click:**
- **F** captures the wrong display, contradicting docs/03 §1.3.
- ⌘A selects on the wrong display.
- A typed W×H goes to the other display.
- Arrows and Space do nothing.

**Fix:**
- Make the pointer's screen key when presenting.
- Call `makeKey()` and `makeFirstResponder` in `mouseEntered`.
- Seed each view's pointer from `NSEvent.mouseLocation`. This also fixes window mode showing no highlight until the mouse moves.

**T-CAP-3 · Every HUD-started capture leaves the user's app unfocused · P0 · S [device]**

**Evidence:**
- The island calls `NSApp.activate(ignoringOtherApps:)` (`AllInOneHUD.swift:120-122`).
- The overlay then records *Kadr* as the app to return to (`SelectionOverlayController.swift:240`) and re-activates it on dismiss (`:462`).
- Esc on the island restores nothing (`AllInOneHUD.swift:150-159`).
- After any capture started from the island (docs/03 §1.4 calls it "the primary way into every capture"), Kadr is active with no window. The next keystroke beeps.

**The same stale state also:**
- names files and History rows after the wrong app, because `frontmostBeforePresent` is set only when nil and cleared only on capture (`AllInOneHUD.swift:64-66`);
- lets the Screen and Tools paths read `NSWorkspace` while Kadr is frontmost, so `{app}` becomes "Kadr".

**Fix:**
- Store the `NSRunningApplication` on *every* present and clear it on dismiss.
- Pass it through every path.
- Give activation back with `NSApp.yieldActivation(to:)` (macOS 14+) on dismiss.
- Never store an `app.kadr.*` app as the one to return to.

**T-CAP-4 · Capture Screen (default target) plays no sound and ignores the after-capture actions · P1 · S**

**Evidence:**
- The default `.allDisplays` always goes through `deliverAll`, even on one display (`+Direct.swift:28-29,62`).
- `deliverAll` skips `CaptureSound.play()`, `applyAfterCaptureActions` and automation `action=annotate|pin` (`+Delivery.swift:21-31`).

**Fix:** share the post-export tail with `deliver`: apply the actions to the active display's file, and play the sound once.

**T-CAP-5 · The island's Screen menu: "Active display" captures all displays, and two rows rewrite a setting · P1 · S**

**Evidence:**
- "Active display" follows `settings.fullscreenTarget` (`AllInOneView.swift:106`).
- "All displays" and "Stitched" permanently change Settings ▸ Capture (`:115,119`).
- There are no checkmarks.

**Fix:** pass the target per call (`captureFullscreen(target:)`), and put a checkmark on the current default.

**T-CAP-6 · Most capture failures only reach the log · P1 · M**

**Silent cases:**
- export or disk failure (`CaptureOutput.swift:94-102`);
- a window closed during the countdown, a display gone, or an SCK error (`+Delivery.swift:127-134`);
- *Capture Previous Area* with nothing to repeat (`AreaCaptureCoordinator.swift:317-320`);
- the OCR helper failing (`+OCR.swift:78-81`);
- the system picker failing (`+Picker.swift:33-36`);
- a scrolling capture with fewer than 2 frames, or a failure to start (`ScrollCaptureCoordinator.swift:184-188,303-307`).

**Fix:**
- Route them all through `FailurePresenter`.
- Beep for "nothing to repeat".
- Also send `automation.report(.failed…)` so CLI callers don't hang.
- Deliver a single scrolling frame as an ordinary capture.

**T-CAP-7 · Every capture PNG-encodes the full-resolution original a second time on the main actor · P1 · S · ✔ verified**

**Evidence:**
- `CaptureProject.write` encodes (`CaptureProject.swift:24-26`) *before* checking whether a project is needed at all (`:41`).
- It runs synchronously from `deliver` (`+Delivery.swift:27,56-60`).
- On a 5K capture that is hundreds of milliseconds on main, counted inside the `selectionToClipboard` budget.

**Fix:** return early when there is no beautify and no default look, and encode off-main.

**T-CAP-8 · Capture Text plus W delivers an image and overwrites the clipboard with it · P1 · S**

**Evidence:** `finishWindow` delivers an image card whatever the purpose (`AreaCaptureCoordinator.swift:349-350,375-403`). The same happens from colour mode.

**Fix:** OCR the window when `purpose == .recognizeText`; otherwise disable W and fix the hint.

**T-CAP-9 · Self-Timer counts down twice · P1 · S**

**Evidence:** `beginSelfTimedAreaCapture` counts down, then `finishRegion` counts down again and re-captures live, throwing the freeze away (`AreaCaptureCoordinator.swift:161-170,425-430`).

**Fix:** carry a flag that marks the timer as already used.

**T-CAP-10 · Scrolling capture control · P1 · M**

**Evidence:**
- Esc and Return on the setup frame only work through a local monitor, so they stop working once the user clicks into the page (`ScrollRegionEditor.swift:177-195`).
- The running HUD has no Esc.
- The command isn't a toggle (`ScrollCaptureCoordinator.swift:121`).
- Auto-scroll asks for Accessibility *after* Start, with a system prompt plus a modal alert on top of a live capture (`+Auto.swift:38-43`, `+Seams.swift:104-114`).

**Fix:**
- Use the Carbon Escape/Return approach from `CountdownEscape`.
- Make the command toggle Stop.
- Check `AXIsProcessTrusted` before Start, with one explainer.

**T-CAP-11 · Include Kadr overlays in captures (X-6) doesn't reach the overlay panels · P2 · S**

**Evidence:**
- `alwaysHiddenFromCaptures` has no `didSet`, and `sharingType` is computed before callers set it (`NonActivatingPanel.swift:21,62`).
- On the macOS 14–15.1 filter path, every registered panel is excluded by ID regardless of the setting.

**T-CAP-12 · Other capture issues · P2 · S each**

- **Confirm-selection mode (off by default) is broken:**
  - A click inside the selection resets it (`SelectionOverlayView.swift:290-295`).
  - The handles are about 4 pt on Retina with a 5 pt hit area (`SelectionHandleLayerGroup.swift:40-73`).
  - There are no edge handles and no "Return to capture" hint.
  - Use about 8 pt handles with a 12–16 pt hit area.
- **VoiceOver floods while dragging:** a high-priority announcement is posted on *every* mouse event, and custom actions are rebuilt in the 120 Hz path (`SelectionOverlayView.swift:390`, `SelectionOverlayAccessibility.swift:158-165`). Announce only on phase changes.
- **Hide desktop during capture:**
  - It is applied *after* the freeze, so area and window captures still show the icons.
  - It runs `killall Finder` twice per capture, which can abort Finder copies (`DesktopHygiene.swift:33-38,79-88`).
  - The wallpaper swap drops the fit/scale options.
- **Countdown Escape cancels automation only once:** `onCancel` is cleared for good after the first Escape (`CaptureCountdown.swift:131-140`).
- **The OCR/colour toast:**
  - It auto-dismisses after 5 s with no pause on hover (WCAG 2.2.1).
  - A QR code whose payload isn't a URL copies nothing.
  - Colour pick reuses the OCR toast, reading "1 line copied", placed on `NSScreen.main`.
  - Give colour pick its own swatch toast.
- **Island Save-target menu:** it toggles `askForSaveDestination`, which only affects the card's Save button (`AllInOneView+Options.swift:6-29`).
- **Timer menu:** it loses the custom duration once a preset is picked, and has no checkmarks (`AllInOneView.swift:160-171`).
- **Island width:** the island is sized from `fittingSize` with no width limit, so its `ViewThatFits` always picks the widest layout (UX-14).
- **Cursor:** the freeze never includes the cursor, so overlay **F** ignores the cursor setting (`AreaCaptureCoordinator.swift:222`).
- **Countdown badge:** it is laid out in `screen.frame`, so it can sit under a notched menu bar. Use `visibleFrame`.
- **Space release:** releasing Space re-anchors the selection at its top-left (`SelectionInteraction.swift:187-197`).
- **Ghost rectangle:** the dashed ghost says "Repeat last area", but nothing on the overlay repeats it. Let Return accept it.
- **Signpost leak:** `hotkeyToOverlay` isn't closed when the overlay task is cancelled after the freeze.
- **Leftover `NSScreen.main` (X-5):**
  - `+ColorPick.swift:33`
  - `TextCaptureToast.swift:35`
  - `WindowBackdropApplier.swift:77`
  - `ScrollCaptureHUD.swift:76`
  - `ScrollRegionEditor.swift:277`
  - `PinManager.swift:69`
  - `RecordingControlBar.swift:447`
  - `CameraPreviewPanel.swift:138,146`
  - `AllInOneHUD.swift:218`

**T-CAP-13 · Exclusion of Kadr windows on macOS 15.2+ depends entirely on `sharingType = .none` · P1 [device]**

**Evidence:** freezes and captures use `SCScreenshotManager.captureImage(in:)` with no window filter (`CaptureEngine+RectCapture.swift:16-21,191-214`).

**Why it matters:** if current macOS versions don't honour `sharingType` for these calls, cards and pins appear in every fullscreen shot.

**Fix:** test first (§8). If they leak, build an `SCContentFilter` that excludes Kadr's windows from `SCShareableContent`.

### 4.5 After capture: cards, pins, History, automation (T-OUT)

**T-OUT-1 · Keys typed in *other apps* act on the hovered card, and ⌫ permanently deletes the capture · P0 · M · ✔ verified**

**Evidence:**
- `startHoverKeyMonitorIfNeeded` (`QuickAccessManager+Idle.swift:137-150`) installs a **global** `keyDown` monitor (active once Accessibility/Input Monitoring is granted, which Kadr asks for).
- `handleHoverKey` acts on unmodified keys with no check of the modifier flags or of which app is frontmost (`:170-211`).
- `delete` trashes the file and purges the library copy permanently (`+Lifecycle.swift:272-287`).

**What happens:** with the pointer resting on the stack (it lives in the corner people park the pointer in):
- **⌫ typed into Slack deletes the capture.** So does ⌘⌫ in Finder.
- Return saves the card and also sends the message.
- Space steals focus to Quick Look.
- A held ⌫ walks the stack as each card slides under the pointer.
- The **local** monitor swallows those keys in Kadr's own History search field, the rename alert and Settings fields whenever the pointer is over a card.

**Fix:**
- Never act on keys from the global monitor.
- Handle card keys in `keyDown` of the overlay's hosting view, only when the overlay panel is key (after a click on a card), as macOS's own screenshot thumbnail does.
- In the local monitor, act only when `NSApp.keyWindow === overlayPanel` and the event has no modifiers other than those a shortcut expects.
- Make card delete **undoable**: trash with `resultingItemURL`, defer the library purge, and show "Moved to Trash · Undo" (the HIG prefers undo to confirmation for frequent destructive actions).

**T-OUT-2 · The feedback banner's buttons (Retry / Save As… / Dismiss) can't be clicked, and the banner eats clicks · P0 · S**

**Evidence:**
- The banner sits top-centre of the full-screen overlay panel (`QuickAccessStackView.swift:71-81`), but only the card column and the peek tab report interactive rects (`:151,:226`).
- `hitTest` therefore returns nil there (`QuickAccessOverlayPanel.swift:43-57`), while the opaque pixels still route clicks to Kadr.
- Warning and error banners never auto-dismiss (`FeedbackStatus.swift:227-233`), so a failure leaves an unclickable click-sink at the top of the screen.
- `feedbackStatus` survives the panel teardown, so a stale error comes back with the next capture.
- When no card is up, the banner doesn't show at all.
- As a result, **OUT-3's recovery path can't be reached**.

**Fix:**
- Anchor the banner to the stack column and add `.reportsInteractiveRect()`.
- Clear it on teardown.
- Route no-card feedback through `FailurePresenter`.

**T-OUT-3 · "Ask where to save" with "Show a card" off loses the capture · P0 · S**

**Evidence:**
- The policy stages the file (`CaptureOutput.swift:234-244`), but `applyAfterCaptureActions` prompts only when a *card* matches the file (`AreaCaptureCoordinator+Delivery.swift:107-111`).
- No card, no panel. The staged file is swept after 24 h.

**Fix:** prompt from the URL directly; factor `promptSave(url:)` out of the card path.

**T-OUT-4 · Changing History retention deletes immediately and permanently; "This session only" wipes the library at once · P0 · S**

**Evidence:**
- `HistoryPane.swift:46` → `applySettingsChange()` → `applyRetention` with `.permanent` (`HistoryController.swift:276-281`).
- For session-only, `sessionStartedAt = launchedAt` (`:67-73`), so everything before this launch is deleted at once. The pane says "the next time Kadr launches" (`HistoryPane.swift:17-18`).
- In the default flow (overlay plus copy, card dismissed), the History copy is the *only* copy.

**Fix:**
- A confirmation sheet with the count and size ("Permanently delete 312 captures (1.4 GB)?").
- Make session-only take effect at the next launch, as the label says.
- Don't run `applyRetention` on every filter change or search keystroke (`HistoryController.swift:165`).

**T-OUT-5 · Save on a History, clipboard or external card doesn't save, and Save As *moves* the library file · P0 · M**

**Evidence:**
- `finalizeIfStaged` returns `true` for anything not staged (`+Lifecycle.swift:250-253`), so Save just dismisses the card.
- Save As moves the content-addressed library blob out of the library (`+Save.swift:61-69`), which breaks the History row.
- Rotate or flip on a History card rewrites the library blob in place (`+Transform.swift:26-37`).
- The Trash button also shows on cards for *user files* opened through `add-quick-access-overlay` or Open from Clipboard (`QuickAccessStackLayout.swift:78-80`). One click trashes the user's own file.

**Fix:**
- Give `QuickAccessItem` an origin: `.staged`, `.saveFolder`, `.library` or `.external`.
- For `.library` and `.external`, Save and Save As *copy* under `displayName`, and transforms operate on a copy.
- Hide Trash for files Kadr didn't create.

**T-OUT-6 · A capture that fails to export disappears silently · P0 · S–M**

**Evidence:**
- `+Delivery.swift:47-50` only reports to automation, and `CaptureOutput.deliverOffMain` only logs (`:99-102`).
- This happens when the save folder is on an unmounted drive, a read-only folder, a full disk, or an expanded name over 255 bytes (`FilenameTemplate` has no cap).

**Fix:**
- Fall back to staging, show the card with "Couldn't save to X — Choose Folder…", and truncate names to about 200 bytes.
- The same applies to recordings: `destinationURL` doesn't create the folder, and a failed move is reported as "could not join the recording" (`RecordingCoordinator+Plumbing.swift:20-34`).

**T-OUT-7 · Delete has no undo, and Trash sits 5 pt from Hide · P1 · S–M**

**Evidence:**
- The two buttons are 22 pt circles 5 pt apart (`QuickAccessCardView+Hover.swift:30-38`).
- History delete sends hash-named blobs to the Trash, so "Put Back" can't restore the row (UX-22).

**Fix:**
- Add the undo banner from T-OUT-1.
- Move Trash away from Hide, or behind ⌥.
- Keep History deletions restorable for the session.

**T-OUT-8 · One long recording can empty the History library · P1 · M**

**Evidence:**
- Recordings are copied into the library at full size (`+Ingest.swift:19-24`).
- The default cap is 5 GB (`SettingKeys.swift:238`).
- `evictLeastRecentlyUsed` loops until the library fits (`HistoryStore.swift:376-395`), which can evict everything, including the item just ingested.

**Fix:**
- Store recordings as a reference plus a poster frame (they already live in the save folder or a studio session), or exclude them from the cap.
- Never evict the item just ingested.
- Warn before evicting more than N items.

**T-OUT-9 · Pin click-through is a trap · P1 · S**

**Evidence:**
- The badge and VoiceOver promise "⌘⌥L to interact" (`PinPanel.swift:430`), but ⌘⌥L exists only inside the pin's context menu, which a click-through pin can't open (`PinPanel+Menu.swift:31-38`).
- The state persists across relaunch, and the only way out is Close All Pins.

**Fix:**
- Add a `CaptureCommand` "Toggle Pin Click-Through" (default ⌘⌥L) that acts on the pin under the pointer, or the newest pin.
- Add "Stop Click-Through" rows to Pins & Overlays.

**T-OUT-10 · Hash-named files leak out of History · P1 · S–M**

**Evidence:** these all hand out `3fa9c1….png`, which fails docs/03 §2 "drag-out delivers a correctly named file":
- drag (`.fileURL`, `HistoryView.swift:185`);
- single Copy (`HistoryController+Library.swift:11-13`);
- Share (`HistoryView.swift:284-289`);
- Reveal;
- the Quick Look title;
- cards opened from History.

**Fix:**
- Hard-link each item under `originalFilename` in a per-session temp folder, as multi-copy already does (`:52-57`).
- Reveal the original path when it still exists.
- Sanitise renames: `/` in a name currently escapes the export folder (`HistoryStore.rename`).

**T-OUT-11 · Save As writes mismatched bytes and extension (OUT-20) · P1 · S**

**Evidence:** `allowedContentTypes = [png, jpeg, heic]` with no extension in the name field (`+Save.swift:37-43`), so an HEIC or JPEG capture can be moved to `name.png` **[device]**. `runModal` plus `activate` block the user and steal focus.

**Fix:** restrict to `item.contentType` with the real extension, or add a format popup that re-encodes off-main. Use `begin`, not `runModal`.

**T-OUT-12 · The URL scheme and message port have no consent model · P1 (P0 before any public build) · M**

**What any web page (after one browser prompt, which Chrome can "always allow") or any local process can do:**
- run `kadr://capture-fullscreen?action=copy`, a silent screenshot to the clipboard (`AutomationRouter.swift:141-165`);
- start a recording with the mic (`record-screen?microphone=true`);
- OCR any readable file to the clipboard (`capture-text?path=~/…`, `AutomationRouter+Text.swift:13-20`);
- make Kadr read arbitrary paths (`pin`, `annotate`, `add-to-history`).

The `CFMessagePort` (`AutomationListener.swift`) likewise checks no sender. Together these let unprivileged code borrow Kadr's Screen Recording grant (a TCC confused deputy). That undercuts PRD principle 4.

**Fix:**
- Add Settings ▸ Advanced ▸ **Allow other apps to control Kadr**: off by default for `kadr://`. The bundled CLI and Shortcuts intents stay allowed.
- On first use, identify the sender (`NSAppleEventManager.currentAppleEvent` → `keySenderPIDAttr`), ask "Allow ‘Raycast’ to control Kadr?", and remember the answer per bundle ID.
- Never run silent capture, `capture-text path=` or `record-*` from a URL without confirmation.
- Check the message-port sender's code signature (audit token → `SecCodeCopyGuestWithAttributes` → team-ID requirement).
- Move the editor's `kadr://add-to-history` to the port or XPC.
- Document all of this in AUTOMATION.md.

**T-OUT-13 · Other after-capture issues · P2 · S each**

- **Displays:**
  - Nothing observes `NSApplication.didChangeScreenParametersNotification`, so after an unplug or a Dock resize, cards can stay off-screen until the next capture.
  - Restored pins aren't clamped to the connected screens (`PinManager.swift:131-144`).
- **Swipe to dismiss** acts on every scroll event, so one long swipe dismisses several cards and a mouse-wheel notch collapses the stack (`+Lifecycle.swift:138-153`). Act once per gesture phase, and only when `hasPreciseScrollingDeltas`.
- **Main-thread file work:**
  - Card delete hashes the file with SHA-256 on the main thread; a multi-GB recording beach-balls (`HistoryController.swift:241-244`).
  - History export is synchronous and uses `try?` (`HistoryController+Library.swift:36-50`).
- **Rescans on every render:** `actions(for:)` rescans studio sessions on every stack render (`QuickAccessStackView.swift:158`), and `fileSizeText` stats the file on every render.
- **Auto-dismiss during work:** OCR and GIF export don't set `activity`, so auto-dismiss can take the card mid-task (OUT-16). GIF export also overwrites an existing `name.gif`.
- **Missing feedback:**
  - Card Copy gives no confirmation.
  - Card OCR with no text announces "0 characters" and opens a toast.
  - A failed editor launch is silent.
- **App Intents:** all capture intents use `openAppWhenRun = true`, which may activate Kadr and change the captured frontmost app **[device]**. Use `false`, as `ToggleRecording` already does.
- **CLI:**
  - It doesn't resolve relative paths: `kadr pin shot.png` resolves against the agent's `/` (`AppCommand.swift:105-107`). Standardise paths in `KadrCLI/main.swift`.
  - The CLI installer replaces or removes *any* `kadr` in `/usr/local/bin` without checking that it is Kadr's symlink (`CLIInstaller.swift:39-90`).
- **Pins:**
  - Scrolling changes opacity, so scrolling a page underneath fades the pin.
  - The menu has no opacity item (docs/03 §4).
  - The hover bar (108 pt) overflows 80 pt pins.
  - Clipboard pins live in `$TMPDIR` and vanish.
- **History:**
  - FTS hits are capped at 200 *before* the type/date filter (`HistoryIndexing.swift:49-58`).
  - Arrow keys don't scroll the focused cell into view.
  - Quick Look shows a single item and doesn't follow the selection (OUT-9).
  - Rename is video-only (docs/03 §5 says every kind).
- **Keyboard:** there is no pointer-free way to reach a card (docs/03 §9). The VoiceOver hint says "Double-tap", which is iOS wording (`QuickAccessCardView.swift:149-154`).

### 4.6 Recording (T-REC)

Most of S0.3, REC-1/2/4/6/7/10/13 and T0.5/T0.6 are really fixed; see §6.

**T-REC-1 · Resume writes the paused stretch back into the file as a frozen frame, and the studio drifts out of step · P0 · S–M · ✔ verified**

**Evidence:**
- `beginSegment()` re-appends `lastVideoBox` with its **pre-pause** presentation time (`RecordingEngine+Lifecycle.swift:183-186`).
- `SegmentWriter.beginSessionIfNeeded` starts the session at that time (`SegmentWriter.swift:172-183`), so `duration = last − first` includes the gap (`:190-194`).
- The stitcher butts full segment durations together (`SegmentStitcher.swift:65-87`).
- The telemetry clock restarts from the first live frame (`RecordingEngine.swift:417-426`), so the two disagree.

**Result:**
- Pause 30 s, resume, stop: the file contains 30 s of frozen picture and silence.
- Every click, keystroke and zoom after the resume lands early by 30 s.
- The camera bubble is out of step by the same amount.
- It fails docs/03 §1.8 "gapless" and docs/12 §1 "length matches".
- Engine tests use a fake writer and can't see it.

**Fix:**
- Re-time the held frame with `CMSampleBufferCreateCopyWithNewTiming` to just before the first live frame after resume (the camera path already does this, `CameraMachinery.swift:296`), or append it with the first live buffer's timestamp.
- Add a real `SegmentWriter` integration test: pause for 2 s and assert the segment duration.

**T-REC-2 · Record without Screen Recording permission leaves a phantom "0:00" recording · P0 · S · ✔ verified**

**Evidence:**
- The countdown claims `.starting` (`RecordingCoordinator+Countdown.swift:36`).
- `start(alreadyClaimed: true)` then returns on `allowCapture == false` without resetting the state (`RecordingCoordinator.swift:215`).
- A first-run tester, or anyone hitting the monthly macOS 15+ re-consent, gets a red menu-bar timer, live controls and a leftover dim.

**Fix:**
- Check permission *before* the countdown.
- On refusal with `alreadyClaimed`, set `state = .idle` and hide the highlight.

**T-REC-3 · The recorder can be reopened during a live or paused take, and starting orphans the running one · P0 · S**

**Evidence:**
- Nothing guards ⇧⌘2 → R or `RecordSetupHUD.present` while recording (`AppDelegate+Commands.swift:79-86,150-158`).
- `startAfterCountdown` has no `!isRecording` guard.
- The start's catch path calls `studio.cancel()` on the *running* take's session (`RecordingCoordinator+Plumbing.swift:77-84`).
- Result: the engine keeps recording with no UI, and the only way out is quitting.

**Fix:**
- Guard both entry points; while recording, focus the live bar instead.
- Guard `startAfterCountdown` on `!state.isActive`.
- Let the catch path tear down only what this start owns.

**T-REC-4 · A new start during `.finishing` corrupts the previous take, and there is no "Saving…" state · P1 · S–M**

**Evidence:**
- `isRecording` is false at `.finishing` (`RecordingCoordinator.swift:163-165`), so the bar and icon go idle while a multi-second join is still running, and a new start is allowed.
- `studio.start` finds the old session still attached, the start fails, and the catch path cancels the *previous* take's session.

**Fix:** keep "Saving…" with a progress indicator on the bar or status item through `.finishing`, and refuse starts until idle. This covers REC-5's "Finishing…".

**T-REC-5 · "Reduce interruptions while recording" is on by default and does nothing · P0 · S · ✔ verified**

**Evidence:** `FocusMode.enable()` only logs (`RecordingCoordinator+Plumbing.swift:176-191`), while the toggle is on by default (`SettingKeys.swift:101`). Testers will trust it, and notification banners will land in their recordings.

**Fix, now:**
- Remove the toggle.
- Replace it with honest copy: "Turn on Do Not Disturb in Control Center before recording."
- Optionally, add a one-time pre-roll tip.

**Fix, later (P3):** an opt-in that runs a user-chosen Shortcut via `/usr/bin/shortcuts run` at start and stop, as CleanShot does. No supported API sets Focus.

**T-REC-6 · Recording an area activates Kadr, so the recorded app loses focus · P1 · S**

**Evidence:**
- `CaptureRegionStage.swift:90-91` calls `NSApp.activate(ignoringOtherApps: true)`.
- The target app starts the take inactive (grey traffic lights), and the first click spent on taking focus back is recorded.

**Fix:** drop the activate, since the non-activating panel can become key, or reactivate the previous app when Record is pressed (REC-16).

**T-REC-7 · The teleprompter and other panels created mid-take are probably recorded · P1 · S [device]**

**Evidence:**
- `teleprompter.start` runs after `engine.start` (`RecordingCoordinator+Plumbing.swift:45-49`), while the exclusion list is fixed at stream start (`RecordingEngine+Targets.swift:70-75`).
- The comment in `TeleprompterPanel.swift:12-15` is stale.

**Fix:**
- Create the panel before `CaptureExclusionPush.into(engine)`.
- More robustly, let `CaptureExclusionRegistry` publish changes and call `SCStream.updateContentFilter(_:)` while live.

**T-REC-8 · Pause and resume tasks overwrite the state after Stop or Discard · P0 · S**

**Evidence:**
- The pause and resume tasks set `.paused` / `.recording` after their `await` without re-checking (`RecordingCoordinator+Control.swift:21-68`).
- Discard stays enabled while settling (`RecordingControlBar+Views.swift:140`).

**Result:**
- Pause, then Discard within about 200 ms: a phantom paused recording that only Stop clears, and Stop then shows an error.
- Resume, then Stop: the 10 Hz tick loop keeps running while idle, breaking **rule 2** (0 % idle CPU), because `resetAfterStopping` doesn't stop ticking (`+Plumbing.swift:105-112`).

**Fix:**
- Guard on the expected state after each `await`.
- Call `stopTicking()` and clear `startedAt` in the reset.
- Queue Stop behind an in-flight transition.

**T-REC-9 · Permission and device problems at start · P1 · S–M**

- **ScreenCaptureKit permission errors look like "not available"** (`RecordingEngine+Targets.swift:12-18`, `RecordingEngine.swift:310-333`). Keep the underlying `NSError` and map `SCStreamError.userDeclined` to permission loss, so a lapsed monthly consent reaches recovery instead of "That screen or window is no longer available". Covers REC-20 too (`RecordingCoordinator+Targets.swift:19-55`).
- **The keystroke overlay prompts at recording start:** Accessibility and Input Monitoring prompts appear *as the recording starts*, over the recorded content (`RecordingOverlaySource.swift:248-262`). Check and prompt from the record panel when the toggle is switched on; at start, only check.
- **The camera turned on in Settings or the pre-roll records nothing:** the device ID stays empty and no camera is resolved (`RecordingCoordinator.swift:374-376`, `CameraMachinery.swift:56`). Resolve the default through `AVCaptureDevice.DiscoverySession`, and put a note on the bar if none exists.
- **Pre-roll toggles skip the access flow**, and resolver downgrades are only logged (`RecordingCoordinator.swift:242-244`). "Mic silent" reads the setting, not the resolved options.
- **The GIF flag carries over:** GIF mode leaks into the next recording after an Esc during the countdown (`RecordingCoordinator+Countdown.swift:103-115`). Reset `wantsGIFExport`, `overrides` and `startedByAutomation`.
- **Multi-display:** the default Screen target and `S` pick the menu-bar display, and the bar goes on `NSScreen.main` (`RecordSetupHUD.swift:240-243`, `RecordingControlBar.swift:447`). Default to the pointer's display.

**T-REC-10 · Robustness on long takes · P1 · S each**

- **Display sleep:** only `.idleSystemSleepDisabled` is held (`RecordingActivity.swift:21`), so a hands-off narrated take can dim or sleep the display. Add `.idleDisplaySleepDisabled` while recording.
- **Saving to another volume:** the copy runs synchronously on the main actor (`StudioSessionRecorder.swift:297-321`), a multi-GB freeze of the agent right after Stop. Move it to a detached task.
- **Quitting during setup** leaves an `InProgress/` folder, and recovery never deletes folders with no playable segment (`RecordingCoordinator+Control.swift:266-275`, `RecordingCrashRecovery.swift:73-75`). This fails docs/12 §2.
- **No disk-space pre-check** before recording (5K60 HEVC is about 80 Mb/s). Use `volumeAvailableCapacityForImportantUsage`.
- **[device]** The held `lastVideoBox` plus `queueDepth = 3` may starve the SCK pool at 1080p60. Add a dropped-frame signpost (rule 8: the engine's `signposter` is never used), then tune.

**T-REC-11 · Other recording issues · P2**

- **The notch hides Stop:** the compact notch shows no Stop, and there is no keyboard way to expand it (UX-16).
- **⌃-click on the recording icon stops the take**, but the spec says it opens the menu (`StatusItemController.swift:134-142`).
- **Restart without confirmation:** the bar's Start Over has none, although Discard does.
- **Microphone menu:** it has no *System Default* row.
- **No VoiceOver announcements** for recording started, paused or saved.
- **Hard-coded Stop shortcut:** the tooltip shows the default shortcut, not the user's binding (`RecordingControlBar+Views.swift:133`).
- **Filenames ignore the user's template:** recordings use "Kadr recording {date} {time}".
- **Raw SCK error strings** appear in the alerts.
- **Log-out and shutdown** during a take show a blocking modal.
- **Self-recorded clicks:** clicks on the teleprompter or camera bubble are recorded as user clicks.
- **Silent downgrades:** halos are silently missing on baked-in window recordings, and overlays are silently skipped for HDR.
- **Rule 5:** extra `DispatchQueue`s in `CameraMachinery.swift:18` and `RecordingOverlaySource.swift:336`.
- **No microphone on macOS 14** (`RecordingOptions.swift:95-105`), although docs/03 promises an AVCaptureSession fallback. Implement it or change the spec (rule 7).
- **REC-11 (`contentRect`)** is still unresolved. The window scale comes from `CGMainDisplayID()` (`RecordingCoordinator+Geometry.swift:94`).

### 4.7 Annotation editor (T-ED)

The drawing and rendering core is solid: ED-1/2/3/5/6/8/10/11/14 are fixed. The document shell is what isn't ready.

**T-ED-1 · Save and reopen are wrong for the common case · P0 · M · ✔ verified**

**Background:** the agent opens `X.kadr` whenever a sibling exists (`QuickAccessManager+Actions.swift:235`), which is true for every capture once a default look or auto-beautify is on, or after any earlier ⌘S. `fileURL` is a `let`, and Save never rebinds the window.

**What goes wrong:**
- **Keep original ON (the default):** ⌘S writes `X annotated.png` plus `X annotated.kadr` (`EditorWindowController+Export.swift:70-92`) and marks the window clean. `X.kadr` is untouched, so reopening from the card shows the old annotations.
- **Keep original OFF:** PNG bytes go into `X.kadr`, which the sidecar then overwrites. **The flattened `X.png` that the card, clipboard and History use is never updated.**
- **Repeated saves pile up files:** every ⌘S creates a new pair (`X annotated 2.png`…), because `CaptureFileWriter` never overwrites (`MediaExport/CaptureFileWriter.swift:62-78`).
- **Every save brings Finder to the front** (`+Export.swift:42,98,135`). That includes the toolbar Save, which docs/03:171 calls "the silent write".
- **Save As doesn't rebind the window:** the title, the proxy icon and the next ⌘S still point at the old file.

**Fix:**
- Keep a mutable `documentURL` and `flattenedURL`.
- When editing a `.kadr`, write the flattened sibling image and the project in place.
- In keep-original mode, create `X annotated.png` once and overwrite it after that.
- Remove `activateFileViewerSelecting` from Save; keep it only for *Show in Finder*.
- Rebind after Save As with `setTitleWithRepresentedFilename`.
- **Longer term (P2, L):** adopt `NSDocument` with `autosavesInPlace`. It brings Revert, Duplicate, Rename, Move To, versions, Open Recent and the standard quit review for free (Ref: *Document-Based App Programming Guide*; HIG › File management).

**T-ED-2 · The editor's app menu: the Window and Services menus are nil · P0 · S · ✔ verified**

**Evidence:**
- `EditorAppDelegate+Menu.swift:16,35` assigns `NSApp.windowsMenu` and `NSApp.servicesMenu`, which are nil in an app without a nib and are never created.
- So there is no ⌘M, no Zoom, no window list and no Bring All to Front. Services has no submenu.

**Fix:**
- Build the Window menu (`performMiniaturize:` ⌘M, `performZoom:`, `arrangeInFront:`), assign `NSApp.windowsMenu`, create `servicesMenu`, and set `helpMenu`.
- Put studio commands (Play/Pause, Split, Trim to Playhead, Add Zoom, Delete Clip) into a Clip/Playback menu. Keyboard-only studio actions are currently invisible to menu search.
- **Reference:** HIG › The menu bar.

**T-ED-3 · Settings "Lock objects…" and "Object shadows…" have no effect · P1 · S · ✔ verified**

**Evidence:**
- The agent writes to domain `app.kadr.Kadr`.
- The editor (`app.kadr.Kadr.Editor`) reads `UserDefaults.standard` (`EditorCanvasPreferences.swift:13-19`, `ObjectShadowPolicy.swift:11-13`).

**Fix:**
- Read with `CFPreferencesCopyAppValue(key, "app.kadr.Kadr" as CFString)`, as `agentKeepsOriginalWhenAnnotating` already does.
- Audit every editor preference read for the same bug.

**T-ED-4 · Text can't be committed from the keyboard, and Esc throws typed text away · P0 · S · ✔ verified**

**Evidence:**
- `TextOverlayEditor.swift:144` matches `insertNewlineIgnoringLineBreaks:`, a selector no key binding ever sends, so the ⌘Return commit never fires.
- Esc reverts to the original string, which deletes a newly typed caption (`:81-93`).

**Fix:**
- Handle ⌘Return in `performKeyEquivalent` of an `NSTextView` subclass.
- Make Esc **commit** and exit, as Keynote, Preview and Figma do, and rely on Undo.

**T-ED-5 · Drag-and-drop onto the canvas never worked · P1 · S · ✔ verified**

**Evidence:**
- The `NSDraggingDestination` methods exist in `AnnotationCanvasView+Drop.swift`, but **`registerForDraggedTypes` is never called in EditorUI**.
- Kadr's own cards drag `NSFilePromiseProvider` promises, which the drop code wouldn't read anyway.

**Fix:** register image and file-URL types plus `NSFilePromiseReceiver.readableDraggedTypes`, and handle promises.

**T-ED-6 · ⌘V with an image on the pasteboard is disabled · P1 · S**

**Evidence:** `validateMenuItem` enables `paste:` only for `.kadrAnnotations` (`EditorWindowController+Commands.swift:113-114`), so the image fallback (`:33-49`) is unreachable. This fails docs/03 P2.

**Fix:** also enable Paste when `canReadObject(forClasses: [NSImage.self])`.

**T-ED-7 · Quitting with unsaved edits doesn't prompt, and nothing restores the windows · P1 · M**

**Evidence:** `applicationShouldTerminate` flushes the autosave and returns `.terminateNow` (`EditorAppDelegate.swift:162-169`). docs/03:171 requires a Save / Don't Save / Cancel prompt.

**Fix:**
- Present each dirty window's close sheet with `.terminateLater`, plus a TextEdit-style *Review Changes…* alert when several are dirty.
- Studio sessions aren't committed on ⌘Q either (T-STU-9).

**T-ED-8 · ⌘S, ⌘P and ⇧⌘C in a Studio or Help window act on a hidden annotation window · P1 · S**

**Evidence:**
- `keyEditor()` falls back to `windows.last` (`EditorAppDelegate.swift:131-134`).
- The Save, Save As and Print items are enabled whenever any annotation editor exists.

**Fix:** move these actions onto `EditorWindowController` so the responder chain decides, and drop the fallback.

**T-ED-9 · Files opened from Finder, including `.kadr` projects, are copied into Application Support and edited there · P1 · M**

**Evidence:**
- `application(_:open:)` imports every file Kadr doesn't own into `~/Library/Application Support/Kadr/Imported` (`EditorAppDelegate.swift:57-71`, `CaptureImporter.swift:46-63`).
- So double-clicking `~/Desktop/Plan.kadr`, editing and saving writes to a hidden folder.
- ⌘O can't open `.kadr` at all (`CaptureImporter.swift:19`), although Info.plist declares Kadr its Owner.

**Fix:**
- Edit `.kadr` in place.
- For imported images, have ⌘S go to Save As or to the capture save folder.
- Add `.kadr` to the Open panel, and add Open Recent.

**T-ED-10 · ⌘` is taken for "Decrease Tool Size" · P1 · S**

**Evidence:** `EditorAppDelegate+Menu.swift:224-228` binds "Decrease Tool Size" to ⌘`, the system's cycle-windows shortcut. A bare ⇧= is bound too, which may take "+" while typing **[device]**.

**Fix:** use ⌘[ / ⌘] (or ⌥⌘− / ⌥⌘=). Never override a system-reserved shortcut (HIG › Keyboard shortcuts).

**T-ED-11 · The canvas is invisible to VoiceOver, and objects can't be reached by keyboard · P2 · L**

**Evidence:**
- `AnnotationCanvasView*` has no accessibility API at all.
- There is no Tab cycling.
- docs/15 says editor VoiceOver is "covered by tests", which overstates it.

**Fix:**
- Give the canvas the `layoutArea` role, with one `NSAccessibilityElement` per annotation (role, label such as "Arrow 3, red", frame) and Press/Delete actions.
- Tab/⇧Tab cycles the selection.

**T-ED-12 · Other editor issues · P2 · S–M each**

- **Copy Without Annotations drops redactions too**, so a blurred secret leaks with one click (`AnnotationExportRenderer.swift:83`). Keep burned-in redactions, or warn. *(Treat this as P1 because it is a privacy promise.)*
- **Window placement:** every editor window opens at the same saved frame, stacked exactly on top of each other. The fit-to-capture sizing runs only on the first launch (`EditorWindowController.swift:180-193`). Cascade the windows and size them from the capture.
- **Print** probably paginates bottom-up and upscales small captures. It is also app-modal (`PaginatedImagePrintView.swift:50-61`) **[device]**.
- **Export Size:**
  - It changes Save silently.
  - It isn't stored in the project.
  - The DPI tag keeps the capture's scale after a downscale, so a 1× export of a Retina capture shows at half size (`ImageEncoder.swift:97-104`).
- **Pin and Share files:** Pin and Share leave `"<stem> pin.png"` and `"<stem> share.png"` next to the user's capture. The share picker is anchored at the window's top-centre, not at the button (`+Export.swift:158-182,222-229`).
- **No drag-out of the *edited* image:** the proxy icon drags the unannotated original in keep-original mode. Add a toolbar drag chip using `NSFilePromiseProvider`.
- **Tool-letter shortcuts:** the tool letters stop working after focusing any inspector control. There is no Tools menu, and Help leaves the letters out.
- **Context menu:** right-click on the canvas does nothing. Add Cut, Copy, Paste, Duplicate, Delete, Arrange, Lock and Edit Text.
- **Undo:**
  - Holding an arrow key adds one undo entry per nudge; coalesce them.
  - Undo entries aren't named, and the canvas's Undo item is always enabled.
- **Save As** has no format or quality control (docs/03:171).
- **Locked objects:** Cut copies but doesn't delete; nudge and duplicate are silent no-ops.
- **Selection:** ⇧-click doesn't extend the selection, although Keynote, Preview and Sketch all do.
- **Inspector shortcut:** it is ⌘I in the spec and ⌥⌘I in the toolbar. Studio-only menu items also appear in the annotation editor.
- **Trim window:**
  - It has no progress, no Cancel and no close or quit guard, so it can leave a partial `…(Trimmed).mov`.
  - It fails silently.
  - Passthrough trims can land up to 2 s early.
- **Clipboard:** it gets PNG only, and copying annotations writes only the private type.
- **Perspective preview [device]:** the live preview is probably projected twice (`AnnotationCanvasView.swift:162-163`, `+Orientation.swift:17-36`), which is ED-4. The text overlay also ignores canvas rotate and flip.
- **Text inspector:** it has no italic or underline, although the model supports both.
- **Spotlights and text rendering:**
  - Spotlights drop the hole `rotation` on the canvas.
  - Wrapped text clips after a side-handle resize.
- **ED-13:** styles don't scale with the capture, although docs/03:153 says they do.
- **Performance and budgets:**
  - There is no rebuild signpost (rule 8).
  - Nothing handles captures over 16384 px.
  - Editor memory budgets are warnings, not assertions.

### 4.8 Studio and export (T-STU)

These are fixed and should stay fixed:
- **Export pipeline:** export integrity (S0.4), the S0.5 set, VFR (STU-A2) and source-time cues (STU-A3).
- **Audio:** every audio track is kept (STU-A1).
- **Render quality:** the damped spring, cursor reconstruction and composer caching.
- **Editing:** the Tidy review list with its 40 % cap.
- **Export UI:** Cancel on the main export, and the close and quit guards for the main export.

**T-STU-1 · A stale render is handed back after an app update, a wallpaper swap or a re-transcription · P0 · S**

**Evidence:**
- The render stamp hashes only the edit and the export settings (`StudioDocumentModel+Export.swift:111-125,292-299`).
- A tester who updates to a build with a render fix gets "already exported, copied the finished file", followed by **the old, buggy movie**. That makes fixes impossible to verify during dogfooding.

**Fix:** add these to the stamp:
- the app build and a `StudioRenderer.version` constant;
- the transcript hash;
- the wallpaper and soundtrack content hashes (give imports content-addressed names).

**T-STU-2 · Editing during an export stamps the wrong edit · P0 · S**

**Evidence:**
- The inspector, timeline and ⌘Z stay live during an export.
- After the `await`, `recordStamp` hashes the *current* edit, and `writeCaptions` uses the current clips (`StudioDocumentModel+Export.swift:168-169,304-310`).
- So the next export of the new edit reuses the old file, and the SRT/VTT timings are wrong.

**Fix:** snapshot the edit and transcript at the start of the export and use the snapshot throughout.

**T-STU-3 · The export frame-rate option is ignored · P1 · S · ✔ verified**

**Evidence:**
- `StudioRenderer.swift:151-155` overwrites `frameRate` with the manifest's.
- The size estimate assumes the chosen rate, so it is off by 2×.
- The intermediate render behind a GIF is always at 60 fps.

**Fix:** use `min(options.frameRate, manifest.frameRate)`, and add a render test that asserts `nominalFrameRate`.

**T-STU-4 · Copy and Share renders can't be cancelled, and nothing guards them on close or quit · P1 · S**

**Evidence:**
- They never set `exportTask` (`StudioDocumentModel+Export.swift:31-78`), so the visible Cancel does nothing.
- ⌘W closes without a prompt, and closing the last window kills the render.
- ⌘C starts a second full render.
- The temp files are named `kadr-copy-<UUID>.mov` (recipients see that name) and are never deleted.
- Share quietly drops the result if the window isn't key.

**Fix:**
- Track all three renders through one `exportTask`.
- Name the files `<project>.mp4` in a per-session staging folder that is purged on close.
- Anchor the share picker to its button.

**T-STU-5 · Cancelling transcription or the model download doesn't stop the helper · P1 · S–M · ✔ verified**

**Evidence:**
- Cancel calls `VisionClient().cancelSpeech()`, which is a *new* connection (`StudioDocumentModel+Speech.swift:102,129`), and the helper builds a `VisionService` per connection (`HelperToolsMain.swift:418-429`). The cancel reaches nothing.
- `LegacyEngine` doesn't keep its recognition task (`SpeechEngines.swift:231-252`).

**Result:**
- A cancelled Tidy keeps burning CPU.
- Pressing Tidy again runs two at once.
- **A cancelled model download keeps downloading.** That is a rule-1 honesty problem: the user was told the network fetch stopped.

**Fix:**
- Hold one `VisionClient` for speech.
- Cancel in the connection's invalidation handler.
- Keep and cancel the `SFSpeechRecognitionTask`.
- Check `Task.isCancelled` in the installer.

**T-STU-6 · "Remove Filler Words" also removes silent on-screen demonstrations · P1 · M**

**Evidence:**
- `silenceCuts` proposes every gap of 1.1 s or more, plus the tail after the last word (`TranscriptCutPlanner.swift:151-187`).
- Every cut is pre-selected.
- In a screen recording, the silent stretches of typing and clicking are often the content.
- The Apply button is the default button, so Return may apply dozens of cuts (`StudioInspector+Speech.swift:153-162`) **[device]**.

**Fix:**
- Protect any interval with clicks, keystrokes or pointer travel; the telemetry is already loaded.
- Shorten long pauses to about 0.5 s instead of deleting them.
- Split the feature into *Filler words* and *Pauses* toggles (the model flags already exist).
- Draw the pending cuts on the timeline.
- Remove the `.defaultAction` binding.
- Plan cuts from the mic track only; today it uses `.all`, so an "um" in recorded system audio gets cut, against docs/03 §1.9.
- **[device]**: check whether Apple's recognisers emit "um"/"uh" at all. If they don't, rename the feature.

**T-STU-7 · GIF export can be clipped or reduced without telling the user · P1 · S–M**

**Evidence:**
- `GIFPlan.fitting` may lower the fps and width or **cut the duration**, and the plan is never shown.
- `estimatedBytes` returns nil for GIF, which breaks docs/03 §1.8 "size estimate before export".
- The GIF phase ignores cancellation, and progress sits at 100 %.
- The resolution labels lie: "Original" really means 800 px.

**Fix:**
- Show the plan in the popover ("12 fps, 640 px, first 90 s").
- Check for cancellation on every frame, and report progress across both phases.
- Give GIF its own pickers.

**T-STU-8 · Delete removes the playhead's clip, not the selected or right-clicked one · P1 · S**

**Evidence:**
- The inspector's "Delete Clip" (`StudioInspector.swift:109-125`), the Delete key and the context menu (`StudioTimelineView.swift:235-243`) all call `removeClipAtPlayhead()`.
- Delete with no selection still removes a clip.

**Fix:** use `removeClip(id:)`, have Delete require a selection, and have the context menu act on the clip under the pointer.

**T-STU-9 · Lifecycle gaps · P1 · S**

- **⌘Q never commits the session:** `commitOnClose` runs only from `windowWillClose`. The session looks crash-interrupted, which inflates "unfinished recordings", and the last 400 ms draft can be lost.
- **No guard on long operations:** quitting during transcription or a model download, during an audio export or during a trim is unguarded. If speech is busy while an export runs, closing the window ends the export (`StudioWindowController.swift:224-243`). Keep one registry of long operations per controller.
- **Duplicate windows:** opening the same recording twice opens two windows that autosave over each other (`EditorAppDelegate.swift:270-283`).
- **Unreadable `edit.json`:** a decode failure (for example after a downgrade) silently falls back to an untouched edit, and the next save **overwrites** the user's edit (`SessionDocument.swift:301-313`). Back up the unreadable file and show a banner.
- **Undo after removal:** undoing the removal of a soundtrack or wallpaper points at a deleted file (`StudioDocumentModel+Audio.swift:49-56`).

**T-STU-10 · Defaults that make files that don't play · P1 · S**

**Evidence:**
- HEVC is the default, while the MP4 hint promises "plays on Windows, browsers and Slack" (`StudioExportOptionsView.swift:113`).
- H.264 at "Original" on 5K is above the hardware encoder's 4096 px limit **[device]**.

**Fix:** default MP4 to H.264, warn when HEVC is chosen, and clamp or warn above 4096 px.

**T-STU-11 · Timeline accessibility and keyboard (UX-32/34) · P2 · M**

**Accessibility (`StudioTimelineView.swift:298-347`, `StudioTimelinePlayhead.swift:56`):**
- Clips have no accessibility element.
- Handles have the `.isButton` trait but no action.
- The playhead has no value.
- Nothing is announced to VoiceOver for export, notices or failures.

**Keyboard:**
- There is no J/K/L, Home/End, ↑/↓ to edit points, or I/O.
- ⇧← and ⇧→ trim asymmetrically by a hard-coded 1/30 s (`StudioTimelineView+Trim.swift:66-89`).
- The clock shows tenths of a second, not frames.
- Snapping can't be turned off.

**Fix:**
- Make clips adjustable elements ("Clip 2 of 5, 0:12–0:31, 2×").
- Make the playhead adjustable.
- Add J/K/L (`AVPlayer.rate` −2/−1/0/1/2), Home/End, ↑/↓ and ⌥[ / ⌥].
- Show `mm:ss:ff`.

**T-STU-12 · Other studio issues · P2**

- **The Dock progress replaces the app icon** with a dark overlay and a red badge that reads like an unread count. It is driven by an inspector view, so hiding the inspector freezes it (`StudioRootView.swift:424-485`).
- **Colour tags:** no `AVVideoColorPropertiesKey` is set on export (tag BT.709), and HDR sources aren't tone-mapped **[device]**.
- **Long recordings [device]:**
  - Telemetry rebasing is O(clips × samples) on the main actor.
  - The transcript lays out every word as a Button (about 9k for 60 minutes).
  - Timeline zoom is capped at 60×.
  - Virtualise the transcript and binary-search clip starts.
- **No drag-out of the export:** docs/03 §6 makes drag the primary share path.
- **Transcript corrections (STU-C4)** have storage but no UI. Per-track volume and mute, a waveform and slow motion are missing.
- **Save panels:**
  - The export Save panel is detached (`panel.begin`) rather than a sheet, and the other panels use `runModal`.
  - The default name is a timestamped folder name.
- **Silent side effects:**
  - SRT and VTT files are written silently next to every export, overwriting existing files with the same name.
  - A failed player item shows a black well with no message.
- **Undo naming:** every change is named "Edit" because `undoMenuTitle` is never used (STU-C8). Two separate slider drags merge into one undo step.
- **Help and first run:** the studio help reads like developer notes and gets shortcuts wrong (`EditorHelp.swift:31-43`), and the studio has no first run (docs/12 §5).
- **Crop handles:** every crop handle shows the left-right resize cursor.
- **Storage:** reported storage leaves out `camera.mov`, the soundtrack and the wallpaper.
- **Idle warm-up:** the speech helper warms up whenever the inspector appears, even for silent recordings.

---

## 5. Cross-cutting themes

These show up in several areas. Fix each once, as a pattern, not per site.

1. **One activation policy.** Five separate places steal or fail to return focus:
   - the island (T-CAP-3);
   - the area stage (T-REC-6);
   - Save As (T-OUT-11);
   - pins' Save;
   - `openAppWhenRun` intents.

   Add `ActivationJuggler.withTemporaryActivation(returningTo:)` and forbid bare `NSApp.activate` outside it. A lint rule can enforce this, the way the zero-network grep does.
2. **One failure surface.** Failures reach the log but not the user in capture, cards, recording, the editor and the studio. Make `FailurePresenter` the only way out: `logger.error` without a presenter call in a user-initiated path becomes a review flag. Checklist: T-CAP-6, T-OUT-2, T-OUT-6, T-REC-9, T-ED-12, T-STU-12.
3. **Undo over confirmation, and confirmation where undo is impossible.** Card delete, History delete, retention, and Discard/Restart recording. HIG: prefer undo for frequent destructive actions, and use `hasDestructiveAction` for the rest.
4. **Menus are part of the product.** Two apps have dead or missing menus (T-SH-1, T-ED-2), and studio commands are not in the menu bar. Add one test per app that walks the main menu and asserts every item resolves to a target.
5. **Multi-display correctness.**
   - Key routing (T-CAP-2).
   - The default recording display (T-REC-9).
   - The remaining `NSScreen.main` sites (T-CAP-12).
   - Screen-change observers (T-OUT-13).

   Make `ActiveScreen` the only way to pick a screen, and add a grep gate for `NSScreen.main` outside it.
6. **Cross-process preferences.** The editor reads its own domain (T-ED-3). Put agent-owned keys behind one `SharedPreferences` accessor in SettingsKit that always reads `app.kadr.Kadr`.
7. **Temp-file hygiene.** Many things are written and never removed:
   - `Kadr-clipboard-*.png` (never deleted, `ClipboardMedia.swift:11,110`);
   - `kadr-copy-/share-*.mov`;
   - editor `pin.png`/`share.png` next to user files;
   - trim partials;
   - `InProgress/` folders;
   - studio sessions with no cap.

   Use one per-launch staging directory, swept at launch. Warn about studio storage above a threshold or under 10 % free disk.
8. **Spelling.** The UI mixes "Colour", "Licence" and "recognises" with the system's "Color". The development language is `en`, so users see US English. Pick one: either US spelling in UI strings, or ship an `en-GB` localization and keep British English there. Code and doc comments can stay as they are.
9. **Localization plumbing.**
   - No package has `defaultLocalization` or a catalog, so the 238 SwiftUI literals in EditorUI are in no catalog.
   - About 190 AppKit literals aren't wrapped in `String(localized:)`.
   - The committed `Kadr/Localizable.xcstrings` is stale against the code.
   - Plurals are built by hand.

   This isn't blocking for English-only dogfooding, but do the plumbing in Wave 3 before strings multiply.
10. **Accessibility debt.** No Accessibility Inspector audit has been run on any of the 11 surfaces (docs/15). Big gaps:
    - the canvas (T-ED-11);
    - the timeline (T-STU-11);
    - pointer-free card access (T-OUT-13);
    - notch expansion.

    Text below the size floor:
    - `RecordingNotchIsland.swift:156` (9 pt)
    - `QuickAccessPeekTab.swift:56` (8.5 pt)
    - `StudioTransportBar.swift:304` (8 pt)
    - `StudioZoomLaneViews.swift` (9 pt)

    Increase Contrast isn't honoured on permission rows or the editor workspace.
11. **Tests that cross seams.** The pause bug (T-REC-1), the frame-rate bug (T-STU-3) and the preferences-domain bug (T-ED-3) all passed unit tests, because a fake writer, a settings struct or an injected suite stood in for the real seam. docs/11's thesis still holds: prefer one integration test that uses the real `SegmentWriter`, the real renderer or the real `UserDefaults` domain over ten tests with fakes.

---

## 6. Status of earlier plans (summary)

Legend: ✅ fixed · ◐ partial · ○ open. File-level evidence is in §4 and in the review notes behind this document.

| Plan | ✅ | ◐ | ○ | Still open that matters for testing |
|---|---|---|---|---|
| docs/11 S0 (ship-blockers) | S0.1, S0.2, S0.3, S0.4 (movie), S0.5 | S0.4 (copy/share/trim/speech close paths) | none | T-STU-4, T-STU-9 |
| docs/11 S1 (gates) | lint, layering, dead-API | perf budgets are still `warn` for editor/studio RSS | the app suite doesn't run | T-REL-7 |
| docs/13 T0–T2 (speech) | T-C1, T-C3, T-H2, T-H3, T-H5, T1.1, T1.3, T1.6, T2.2–T2.5 | T-C2, T-H1, T-H4, T1.5 | none | T-STU-5, T-STU-6 |
| docs/14 §5.1–5.3 (shell) | UX-06, 07, 08, 08B, 11, 12 | UX-01–05, 08A, 09, 10, 13 | none | T-SH-4, T-SH-8, §5.9, §5.10 |
| docs/14 §5.4–5.7 (surfaces) | UX-15, 17A, 19, 20, 23, 30, 30C, 31, 36A | UX-14, 16, 17, 17B, 17C, 18, 21, 22, 24, 25, 26, 27, 28, 29, 30A, 30B, 32–36 | none | T-OUT-1, T-OUT-2, T-ED-2 |
| docs/16 §3 (X) | X-1, X-6 (settings) | X-2, X-3, X-4, X-5, X-7 | none | T-SH-7, T-CAP-12 |
| docs/16 §4 (CAP) | CAP-1, CAP-9 | CAP-3, CAP-8, CAP-11 | none | T-CAP-3, T-CAP-5 |
| docs/16 §5 (OUT) | OUT-1, 4, 5, 7, 11, 14, 15, 17, 19 | OUT-3, 6, 8, 9, 10, 16 | OUT-20 | T-OUT-3, T-OUT-5, T-OUT-11 |
| docs/16 §6 (ED) | ED-1, 2, 3, 5, 6, 8, 10, 11, 12, 14 | ED-4, 7, 9, 15, 16, 17 | ED-13 | T-ED-1, T-ED-7 |
| docs/16 §7 (REC) | REC-1, 2, 4, 6, 7, 10, 13, 19 | REC-3, 5, 8, 9, 11, 12, 14, 16, 17, 18 | REC-20 | T-REC-1, T-REC-9 |
| docs/16 §8 (STU) | A1–A6, B1–B3, B6, C1, C3, C5, C7 | B4 (different approach, fine), B5, C2, C6, C8, C9 | C4 | T-STU-3, T-STU-12 |
| docs/16 §9 (APP) | APP-2, 10, 11, P4 | APP-1, 3, 7, 8, 13, P2 | APP-4, P1 | T-SH-1, T-SH-5 |

Once this plan is accepted, mark the superseded items in docs/14 and docs/16 as "→ docs/17 T-xxx", so there is one open list.

---

## 7. Internal testing program

### 7.1 Cohort and cadence
- **5–8 testers**, chosen to cover the docs/12 §3 matrix:
  - at least one Intel Mac;
  - one macOS 14 machine;
  - one notched MacBook;
  - one mixed-DPI dual display;
  - one display arranged *above* the primary;
  - one tester who relies on VoiceOver or full keyboard access, if possible.
- **Weekly builds** on the Sparkle `beta` channel (T-REL-4). **Hotfix builds** within 24 h for any P0.
- **Two weeks** per round. Each week has a focus: week 1 is capture and cards, week 2 is recording and studio.

### 7.2 What testers get
- `TESTING.md` (T-DIAG-4), covering:
  - install, permissions and the monthly re-consent;
  - Report a Problem;
  - the Known Issues list;
  - what not to test yet.
- A **15-minute smoke script** per build (§7.3) and a **weekly focus script**, drawn from docs/12 §1–2.
- A form or issue template (`bug.yml`) with fields for:
  - version and build;
  - what you did, what you expected, what happened;
  - a screen recording (Kadr itself!);
  - the attached diagnostics zip.

### 7.3 Smoke script (every build, about 15 min)

Every run of this script must pass before a build goes to testers.

1. **Fresh install:** run `Scripts/uninstall.sh`, install the DMG, move the app to /Applications, launch. Onboarding → grant Screen Recording → relaunch → practice capture.
2. **Capture from the island (⇧⌘2):**
   - area, window and screen captures;
   - after each one, **type into the previous app without clicking**, which checks T-CAP-3.
3. **Card:**
   - drag the card into Finder and into Slack/Mail (check the name);
   - Copy, Save, Annotate, then Delete and **Undo**;
   - with the pointer resting on a card, type ⌫ into another app: nothing must happen (T-OUT-1).
4. **Editor:**
   - add an arrow and text (⌘Return and Esc both keep the text);
   - ⌘S twice (one file, Finder not activated);
   - close, reopen from the card: the edits are there;
   - ⌘M works.
5. **Capture Text and Colour pick by click.**
6. **Recording:**
   - record 30 s with the mic;
   - Pause 10 s, Resume, Stop: the file is about 20 s and gapless (T-REC-1);
   - open it in the studio, cut one clip, export MP4 at 30 fps: check the fps (T-STU-3);
   - export again: it reuses the file (the stamp is correct).
7. **Automation:** `open "kadr://capture-fullscreen?action=copy"` must ask for consent once T-OUT-12 lands.
8. **Diagnostics:** Help ▸ Report a Problem… produces a zip containing logs and `system.json`.
9. **Updates:** Check for Updates… finds the next build on the beta channel.
10. **Idle budgets:** run `make perf` on the release build (idle RSS below 30 MB, 0 % CPU over 60 s).

### 7.4 Triage
- Use GitHub labels: `dogfood`, `P0`–`P3`, and the area labels `capture`, `cards`, `history`, `recording`, `editor`, `studio`, `shell` and `release`.
- Run a triage twice a week. A P0 gets a hotfix build. A P1 is fixed, or added to Known Issues, by the next weekly build.
- Every fixed bug that a tester found gets a regression test at the **seam** where it lived (§5.11), or a row in docs/12.

### 7.5 Exit criteria: internal to external beta
- Zero open P0. No P1 older than one build.
- No crash or hang payloads in MetricKit across the cohort for the last full week. This depends on testers attaching diagnostics; ask for them weekly.
- The docs/12 §1 flagship script passes on Apple Silicon and on Intel.
- docs/12 §3 display matrix ticked, and §8 below resolved.
- Accessibility Inspector audits attached for all 11 surfaces, with no *error*-level issues.
- `make all` green on a clean checkout, with the app suite actually running.
- Time to first capture after install under 2 minutes for every new tester (PRD §4). Measure it by watching, not with telemetry.

---

## 8. Device-verification rows to add to docs/12

Each row can only be settled on a real Mac, and each one decides a fix above.

- **Screen-capture exclusion:**
  - [ ] **`sharingType = .none` on macOS 15.2+ and 26.** Take two fullscreen captures in a row with a card and a pin visible. Do they appear? (T-CAP-13)
  - [ ] **Teleprompter in a display recording.** Is the script panel in the file? (T-REC-7)
- **Focus and keyboard routing:**
  - [ ] **Island focus return.** After an island capture, does the next keystroke reach the previous app? (T-CAP-3)
  - [ ] **Multi-display overlay.** Press F with the pointer on the second display before clicking. (T-CAP-2)
  - [ ] **Area recording focus.** Is the target app active when the take starts? (T-REC-6)
- **Recording:**
  - [ ] **Pause/Resume.** Pause 10 s: is the file length equal to the recorded time? (T-REC-1)
  - [ ] **Sleep and stream death.** A 20-minute hands-off take with the display-sleep timeout at 10 minutes. Does the display sleep, and does the stream die? (T-REC-10)
  - [ ] **Hotkey conflicts.** Does Carbon registration report conflicts with other apps on 15 and 26? (T-SH-7)
- **Speech:**
  - [ ] **Fillers.** Do Apple's recognisers emit "um"/"uh"? (T-STU-6)
  - [ ] **Long audio.** Does on-device file recognition finish a 30-minute track on macOS 14 and 15? (T-STU-5, T-STU-6)
  - [ ] **Return key.** Does Return in the studio reach the Tidy "Apply" default button? (T-STU-6)
- **Export:**
  - [ ] **H.264 at 5K.** Does export succeed or fail? (T-STU-10)
  - [ ] **Colour.** Do exported colours match the preview in QuickTime? (T-STU-12)
- **Editor:**
  - [ ] **Print.** What order do the pages of a tall capture print in? (T-ED-12)
  - [ ] **Perspective.** Does the live perspective preview match the export? (ED-4)
- **Card saves:**
  - [ ] **Save As extension.** Save As on an HEIC card: extension and bytes. (T-OUT-11)
- **First run and install:**
  - [ ] **First-run permission.** How many dialogs appear on first Screen Recording use? (T-SH-4)
  - [ ] **Default save folder.** Does the first save to `~/Desktop` prompt, and does `~/Pictures/Kadr`? (T-SH-4)
  - [ ] **Updates.** Does the Sparkle update window from the LSUIElement agent come to the front, and does it survive the 120 s backstop? (T-REL-4)
  - [ ] **TCC across signing change.** From a `make install` build to a Developer ID build: which grants re-prompt? (T-REL-1)
- **Open question:**
  - [ ] **docs/12 §6 `contentRect`.** Now possible, with the runtime geometry-probe toggle (T-DIAG-3).

---

## 9. Spec and document changes this plan requires (rule 7)

- **docs/03 §1.1 (freeze):** the freeze *includes* the menu bar. The code documents why at `Capture.swift:227-232`; the spec says the menu bar is excluded.
- **docs/03 §1.1 (modifier keys):**
  - ⇧ means a 1:1 square (not aspect lock).
  - Arrow keys nudge by 1 pt (not 1 px).
  - Either change the code or the spec.
- **docs/03 §1.8:**
  - Replace the auto-DND promise with the honest copy (T-REC-5).
  - Microphone on macOS 14: implement it or drop it (T-REC-11).
- **docs/03 §5 and §8.1:**
  - The Recent submenu and ⇧⌘L are gone (X-7).
  - ⌃-click on the recording icon opens the menu.
- **docs/03 §2:** card keys act only when the overlay panel is key (T-OUT-1). That is a deliberate move away from CleanShot's hover keys, because of data loss.
- **docs/03 automation:** the consent model (T-OUT-12). Also fix `docs/AUTOMATION.md`:
  - it lists `fps` and `microphone` for `toggle-recording`, which the parser rejects;
  - it omits four App Intents.
- **CLAUDE.md rule 1:** opening a user-chosen URL in the user's browser (Report a Problem, OCR links) is not app networking. Say so explicitly.
- **docs/12:**
  - Use the correct log predicate, `subsystem == "app.kadr.Kadr"`.
  - Add the §8 rows.
  - Add the §7.3 smoke script as a new §0.
- **docs/15:** replace "covered by tests" for editor VoiceOver with the true state.
- **docs/00-README:** add this document to the reading order.
- **Memory `kadr-known-failing-tests`:**
  - `OverlayEngagementTests` passes again.
  - The suite crashes at bootstrap because of `ShortcutDefaultsMigrationTests`.
  - `VisionClientTests` times out.

---

## 10. Apple references used

- *Human Interface Guidelines*:
  - The menu bar
  - Menus
  - Settings
  - Alerts
  - Undo and redo
  - Drag and drop
  - File management
  - Keyboard shortcuts
  - Accessibility
  - Buttons (default, destructive)
  - Share (`NSSharingServicePicker` anchoring)
- *Notarizing macOS software before distribution*
- *Distributing software outside the Mac App Store* (`xcodebuild -exportArchive`, `method = developer-id`)
- *Describing use of required reason API* (`PrivacyInfo.xcprivacy`)
- Sparkle 2 documentation:
  - EdDSA signing
  - `SPUUpdaterDelegate.allowedChannels(for:)`
  - gentle reminders for background apps
  - code-signing order
- MetricKit: `MXMetricManager`, `MXMetricManagerSubscriber`, `MXDiagnosticPayload`
- Unified logging: `OSLogStore`, `Logger` privacy (`.private(mask: .hash)`), `man 5 os_log` (`OSLogPreferences`)
- ScreenCaptureKit: `SCStream.updateContentFilter(_:)`, `SCStreamError.userDeclined`, `SCShareableContent`
- AppKit:
  - `NSApplication.yieldActivation(to:)` (macOS 14)
  - `NSWindow.sharingType`
  - `NSFilePromiseProvider` / `NSFilePromiseReceiver`
  - `NSDocument` autosave-in-place
  - `NSAlert` button `hasDestructiveAction`
- AVFoundation: `CMSampleBufferCreateCopyWithNewTiming`, `AVVideoColorPropertiesKey`, `AVCaptureDevice.DiscoverySession`
- `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled])`
- `SMAppService` (login item), `AXIsProcessTrusted`, `CGPreflightListenEventAccess`
