# Releasing Kadr

Everything Gatekeeper and Sparkle need, and why each step exists. Sequoia removed the
Control-click bypass for unsigned apps, so an unnotarized build is not a lesser
experience — it is one most users cannot open at all.

`Scripts/release.sh` is the one definition of a release (`make dmg` runs it). It fails on
every missing prerequisite rather than skipping a step, so if it prints **Done** the DMG is
signed, notarized, stapled, in the appcast and its symbols are kept.

## Values only the owner can supply

These are deliberately not in the repository. `release.sh` refuses to run without them.

| What | Where it goes | Why |
|---|---|---|
| Apple team ID | `KADR_TEAM_ID` in the environment | Substituted into `Distribution/ExportOptions.plist` (`__KADR_TEAM_ID__`) for `-exportArchive`. |
| Sparkle public EdDSA key | `KADR_SPARKLE_PUBLIC_ED_KEY` in the environment | Passed as a build setting and written to `SUPublicEDKey` by `Config/Kadr-Info.plist`. Empty in local builds. |
| Feed URL | `KADR_APPCAST_URL` in the environment (optional) | Written to `SUFeedURL`. The default is `raw.githubusercontent.com/kadr-app/kadr/main/appcast.xml`, which only works once that repository is public — `release.sh` checks the URL answers before building. |

## One-time setup

1. **A Developer ID Application certificate.** It needs the Account Holder role on the
   Apple Developer team. An "Apple Development" certificate is not enough: it signs for
   your own machines only.

2. **A notarytool profile**, from an App Store Connect API key rather than an
   app-specific password, so CI can use the same credential later:

   ```sh
   xcrun notarytool store-credentials kadr-notary \
     --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

3. **A Sparkle EdDSA key pair.** Build once so Sparkle's tools land in DerivedData, then:

   ```sh
   "$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f | head -1)"
   ```

   It stores the **private key in your login Keychain** (item "Private key for signing
   Sparkle updates") and prints the public key. Export the public key as
   `KADR_SPARKLE_PUBLIC_ED_KEY` — do not add it as an `INFOPLIST_KEY_` build setting:
   Xcode drops Info.plist keys it does not recognise, which is how `SUFeedURL` went missing
   from every build before docs/17 T-REL-2. Back the private key up
   (`generate_keys -x <file>`) somewhere offline: losing it means no installed copy can
   ever update again.

4. `brew install create-dmg`

## Cutting a release

```sh
KADR_TEAM_ID=ABCDE12345 KADR_SPARKLE_PUBLIC_ED_KEY=… \
  make dmg VERSION=0.9.0 CHANNEL=beta
```

or `Scripts/release.sh --version 0.9.0 --channel beta` directly. In order it:

1. Checks the certificate, the notary profile, the key, the feed and the build number.
   The build number defaults to `git rev-list --count HEAD` and must be greater than the
   newest `<sparkle:version>` already in `appcast.xml`, or Sparkle would never offer it.
2. Archives with `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `KADR_GIT_COMMIT`
   stamped in, so Settings, About and the diagnostics zip all say which build this is.
3. Exports with `xcodebuild -exportArchive` (`method = developer-id`). The exporter signs
   nested code inside out — the `kadr` CLI, the editor and its XPC helper, Sparkle's
   helpers — and keeps each target's entitlements. Hand re-signing with `codesign --force`
   dropped the camera and microphone entitlements.
4. Verifies: the entitlements include camera and audio input, `codesign --verify --deep
   --strict`, a Developer ID authority, and the Info.plist keys and version.
5. Keeps symbols (below), builds and signs the DMG, notarizes it (printing
   `notarytool log` on rejection), staples it, and asks Gatekeeper (`spctl`) about the app
   inside.
6. Signs the DMG for Sparkle, adds it to `appcast.xml` on the chosen channel, and rewrites
   `Distribution/kadr.rb` with the new version and sha256.

Then, by hand:

1. Tag `v<version>-b<build>` (the script prints it) and publish the DMG as a GitHub release
   under that tag.
2. Commit `appcast.xml` and `Distribution/kadr.rb`. The appcast commit is the publish.
3. For a stable release, open a PR against `homebrew/homebrew-cask`.

## Channels

Dogfood builds go out with `--channel beta`: the item carries
`<sparkle:channel>beta</sparkle:channel>`, and only installs with Settings ▸ Updates ▸
**Receive beta builds** switched on see it. Stable items carry no channel and reach
everyone. `--release-notes-link` adds a `<sparkle:releaseNotesLink>`; point it at the
matching `CHANGELOG.md` section.

## Symbols

Every release keeps its archive and dSYM UUIDs under `dist/symbols/<version>-<build>/`
(`dist/` is ignored by git; back it up). To symbolicate a tester's `.ips` report:

```sh
grep <uuid-from-the-report> dist/symbols/*/uuids.txt
atos -arch arm64 -o dist/symbols/0.9.0-512/Kadr-0.9.0-512.xcarchive/dSYMs/Kadr.app.dSYM/Contents/Resources/DWARF/Kadr \
     -l <load-address> <frame-address>
```

or double-click the `.xcarchive` to import it into Xcode's Organizer, which symbolicates
crash logs dropped on it.

## Moving testers from `make install` builds

A `make install` build is development-signed; a release is Developer ID-signed. The
designated requirement changes, so macOS treats them as different apps for privacy:
Screen Recording, Accessibility and Input Monitoring each ask **once more** after the
switch. Tell testers before their first Developer ID build.

## Checks before tagging

```sh
make all                    # lint, every test, layering and size gates
make size-gate              # the archive-measured DMG against PRD §8
make perf                   # the idle budgets
```
