# Security

## What Kadr does and does not do

Kadr works entirely on your Mac. It has no account, no analytics and no upload feature.
Its only network traffic is:

- **Sparkle's update check** — it downloads the appcast and, if you accept, a signed DMG.
  Updates are verified with an EdDSA signature and Apple notarization.
- **Asking macOS to install a speech model**, when you choose filler-word removal in the
  studio. Transcription itself runs on device.

Both are enforced in CI by `Scripts/check-layering.sh`. Help ▸ Report a Problem… opens a
web page in your browser; Kadr itself sends nothing, and the diagnostics zip is attached
by you.

## Reporting a vulnerability

Please report privately, not in a public issue:

- Use GitHub's **Report a vulnerability** (Security ▸ Advisories) on this repository, or
- email **security@kadr.app** <!-- PLACEHOLDER: replace with the owner's real address -->.

Include the Kadr version and build (Settings ▸ Updates), the macOS version, and steps to
reproduce. We aim to acknowledge within three working days and to ship a fix for anything
serious in the next build.

Issues we especially want to hear about: anything that sends user data off the Mac, a way
to install an update that is not signed by us, bypasses of macOS privacy permissions, and
the `kadr://` URL scheme or `kadr` CLI acting without the user's consent.

## Supported versions

Only the latest build on each update channel (beta and stable) receives fixes.
