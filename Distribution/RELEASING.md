# Releasing Kadr

Everything Gatekeeper needs, and why each step exists. Sequoia removed the Control-click
bypass for unsigned apps, so an unnotarized build is not a lesser experience — it is one
most users cannot open at all.

## One-time setup

1. **Apple Developer membership** ($99/yr, funded by sponsors per PRD §9) and a
   **Developer ID Application** certificate in the Keychain. An "Apple Development"
   certificate is not enough: it signs for your own machines only.

2. **A notarytool keychain profile**, so no credential ever appears in a script:

   ```sh
   xcrun notarytool store-credentials kadr-notary \
     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
   ```

3. **A Sparkle EdDSA keypair.** Build the app once so Sparkle's tools land in DerivedData,
   then:

   ```sh
   $(find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f | head -1)
   ```

   It prints a public key and stores the private key in the Keychain. Put the public key
   in the app target's `INFOPLIST_KEY_SUPublicEDKey` build setting. The private key never
   leaves the machine, and Sparkle refuses any update whose signature does not verify
   against the public one — which is what makes the update channel safe to be the app's
   only network connection.

4. `brew install create-dmg`

## Cutting a release

```sh
Scripts/release.sh --version 1.0.0 --build 1
```

That archives with Developer ID, signs nested code inside out (the XPC helper and the
embedded editor before the app that contains them), builds a DMG, notarizes it, staples
the ticket so it opens offline, signs it for Sparkle, and appends it to `appcast.xml`.

Then:

1. Create a GitHub release tagged `v1.0.0` and attach the DMG.
2. Commit the updated `appcast.xml`. Sparkle reads it from the raw GitHub URL in
   `SUFeedURL`, so the commit is the publish.
3. Update `Distribution/kadr.rb` with the new version and sha256, and open a PR against
   `homebrew/homebrew-cask`.

## Checks before tagging

```sh
Scripts/check-layering.sh   # zero network outside Sparkle, module boundaries intact
Scripts/check-perf.sh       # the PRD §8 budgets
Scripts/check-size.sh       # bundle under 15 MB
```
