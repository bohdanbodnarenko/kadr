#!/bin/bash
#
# Kadr — build, sign, notarize and publish a release (docs/04 §10, PRD §9).
#
# Everything Gatekeeper needs, in order: archive with Developer ID, notarize, staple,
# package as a DMG, sign the DMG for Sparkle, and append it to the appcast.
#
# Sequoia removed the Control-click bypass for unsigned apps, so an unnotarized build is
# not a lesser experience — it is one most users cannot open at all. This is not optional
# tooling.
#
# Prerequisites (all one-time):
#   * A "Developer ID Application" certificate in the Keychain ($99/yr membership).
#   * A notarytool keychain profile:
#       xcrun notarytool store-credentials kadr-notary \
#         --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#   * A Sparkle EdDSA keypair. Build once, then run Sparkle's generate_keys, and put the
#     public key in the app's Info.plist as SUPublicEDKey. The private key stays in the
#     Keychain and never leaves this machine.
#   * create-dmg: brew install create-dmg
#
# Usage:
#   Scripts/release.sh --version 1.0.0 --build 1 [--notary-profile kadr-notary] [--skip-notarize]
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }
step() { printf '\n%s▸ %s%s\n' "$GREEN" "$1" "$OFF"; }
fail() { printf '%s✘ %s%s\n' "$RED" "$1" "$OFF"; exit 1; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }

VERSION=""
BUILD=""
NOTARY_PROFILE="kadr-notary"
SKIP_NOTARIZE=0
OUTPUT="dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "$VERSION" ] || fail "--version is required (for example 1.0.0)"
[ -n "$BUILD" ] || fail "--build is required (a monotonically increasing integer)"

ARCHIVE="$OUTPUT/Kadr.xcarchive"
APP="$OUTPUT/Kadr.app"
DMG="$OUTPUT/Kadr-$VERSION.dmg"

# ---------------------------------------------------------------- preflight
step "Checking prerequisites"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "no Developer ID Application certificate — Gatekeeper will reject the build"
note "Developer ID certificate found"

command -v create-dmg >/dev/null || fail "create-dmg is missing: brew install create-dmg"

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" \
    "$(dirname "$0")/../Kadr/Info.plist" 2>/dev/null || true)
if [ -z "$PUBLIC_KEY" ]; then
    note "SUPublicEDKey is not set yet — updates will not verify until it is"
    note "run Sparkle's generate_keys and add the public key to the app's Info.plist"
fi

# ---------------------------------------------------------------- build
step "Archiving $VERSION ($BUILD)"
rm -rf "$ARCHIVE" "$APP"
mkdir -p "$OUTPUT"

xcodebuild archive \
    -workspace Kadr.xcworkspace \
    -scheme Kadr \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Automatic \
    -quiet

cp -R "$ARCHIVE/Products/Applications/Kadr.app" "$APP"

# ---------------------------------------------------------------- sign
step "Signing with Developer ID and the hardened runtime"
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
note "identity: $IDENTITY"

# Inside out: nested code has to be signed before whatever contains it.
find "$APP/Contents/XPCServices" "$APP/Contents/Applications" "$APP/Contents/Frameworks" \
    -maxdepth 1 -mindepth 1 2>/dev/null | while read -r nested; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
    note "signed $(basename "$nested")"
done
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# ---------------------------------------------------------------- package
step "Building the disk image"
rm -f "$DMG"
create-dmg \
    --volname "Kadr $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "Kadr.app" 140 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    "$DMG" "$APP" >/dev/null

codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# ---------------------------------------------------------------- notarize
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    # Stapling is what lets the DMG open on a Mac that is offline.
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    note "skipping notarization — the result will not open on another Mac"
fi

# ---------------------------------------------------------------- appcast
step "Signing for Sparkle and updating the appcast"
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    note "sign_update not found; build once so Sparkle's tools are in DerivedData"
else
    SIGNATURE_OUTPUT=$("$SIGN_UPDATE" "$DMG")
    note "$SIGNATURE_OUTPUT"
    Scripts/update-appcast.sh \
        --version "$VERSION" \
        --build "$BUILD" \
        --dmg "$DMG" \
        --signature-line "$SIGNATURE_OUTPUT"
fi

step "Done"
note "$DMG"
note "next: create a GitHub release with that DMG, then commit the updated appcast.xml"
