#!/bin/bash
#
# Kadr — build, sign, notarize and publish a release (docs/04 §10, PRD §9, docs/17 §4.1).
#
# In order: archive, export with Developer ID, verify, package as a DMG, notarize,
# staple, keep the symbols, sign the DMG for Sparkle, append it to the appcast and
# bump the Homebrew cask.
#
# Sequoia removed the Control-click bypass for unsigned apps, so an unnotarized build is
# not a lesser experience — it is one most users cannot open at all.
#
# Signing is `xcodebuild -exportArchive`, not `codesign --force` by hand. Hand re-signing
# dropped the camera and microphone entitlements (the hardened runtime then silently
# denies both) and left nested code — the CLI, the editor's XPC helper and Sparkle's
# helpers — with development signatures notarization rejects (T-REL-3). The exporter
# signs inside out and keeps each target's entitlements.
#
# Every missing prerequisite is a hard failure. A script that prints "Done" after
# skipping the appcast is how a release goes out that no installed copy can see.
#
# Prerequisites (all one-time, see Distribution/RELEASING.md):
#   * A "Developer ID Application" certificate in the Keychain.
#   * KADR_TEAM_ID in the environment (the Apple team that owns that certificate).
#   * A notarytool keychain profile (default name kadr-notary).
#   * KADR_SPARKLE_PUBLIC_ED_KEY: the public half of Sparkle's EdDSA pair.
#   * create-dmg: brew install create-dmg
#
# Usage:
#   KADR_TEAM_ID=ABCDE12345 KADR_SPARKLE_PUBLIC_ED_KEY=… \
#     Scripts/release.sh --version 0.9.0 [--build N] [--channel beta|stable]
#                        [--notary-profile kadr-notary] [--skip-notarize]
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }
step() { printf '\n%s▸ %s%s\n' "$GREEN" "$1" "$OFF"; }
fail() { printf '%s✘ %s%s\n' "$RED" "$1" "$OFF" >&2; exit 1; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }
need() { command -v "$1" >/dev/null || fail "$1 is missing${2:+: $2}"; }

VERSION=""
BUILD=""
CHANNEL="beta"
NOTARY_PROFILE="kadr-notary"
SKIP_NOTARIZE=0
OUTPUT="dist"
APPCAST="appcast.xml"
# The feed host is the owner's decision (T-REL-4). This default is the historical one;
# override it with KADR_APPCAST_URL once the public host exists. It is checked for
# reachability below, so a private repository's 404 fails here, not on testers' Macs.
FEED_URL="${KADR_APPCAST_URL:-https://raw.githubusercontent.com/kadr-app/kadr/main/appcast.xml}"
PUBLIC_KEY="${KADR_SPARKLE_PUBLIC_ED_KEY:-}"
TEAM_ID="${KADR_TEAM_ID:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "$VERSION" ] || fail "--version is required (for example 0.9.0)"
case "$CHANNEL" in beta|stable) ;; *) fail "--channel must be beta or stable" ;; esac
# Sparkle compares CFBundleVersion, so it must only ever increase. The commit count does,
# on one branch, without anybody having to remember the last number (T-REL-5).
[ -n "$BUILD" ] || BUILD=$(git rev-list --count HEAD)
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "--build must be an integer, got $BUILD"
COMMIT=$(git rev-parse --short HEAD)
[ -z "$(git status --porcelain --untracked-files=no)" ] \
    || note "the working tree has uncommitted changes — $COMMIT will not describe this build exactly"

ARCHIVE="$OUTPUT/Kadr-$VERSION-$BUILD.xcarchive"
EXPORT="$OUTPUT/export-$VERSION-$BUILD"
APP="$EXPORT/Kadr.app"
DMG="$OUTPUT/Kadr-$VERSION.dmg"
SYMBOLS="$OUTPUT/symbols/$VERSION-$BUILD"
TAG="v$VERSION-b$BUILD"

# ---------------------------------------------------------------- preflight
step "Checking prerequisites"

need xcodebuild
need create-dmg "brew install create-dmg"
need curl
need dwarfdump
need python3

[ -n "$TEAM_ID" ] || fail "KADR_TEAM_ID is not set — the export needs the team that owns the Developer ID certificate"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || fail "no Developer ID Application certificate — Gatekeeper will reject the build"
note "Developer ID certificate found, team $TEAM_ID"

[ -n "$PUBLIC_KEY" ] || fail "KADR_SPARKLE_PUBLIC_ED_KEY is not set — without it Sparkle falls back to code-signing-only validation"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool profile '$NOTARY_PROFILE' is missing or invalid — see Distribution/RELEASING.md"
fi

curl -fsSIL --max-time 20 "$FEED_URL" >/dev/null \
    || fail "the appcast is not reachable at $FEED_URL — a private repository's raw URL is a 404 for every tester"
note "feed reachable: $FEED_URL"

[ -f "$APPCAST" ] || fail "$APPCAST is missing"
NEWEST=$(sed -n 's/.*<sparkle:version>\([0-9]*\)<\/sparkle:version>.*/\1/p' "$APPCAST" | sort -n | tail -1)
if [ -n "$NEWEST" ] && [ "$BUILD" -le "$NEWEST" ]; then
    fail "build $BUILD is not newer than build $NEWEST already in $APPCAST — Sparkle would never offer it"
fi
note "version $VERSION, build $BUILD, commit $COMMIT, channel $CHANNEL"

# ---------------------------------------------------------------- archive
step "Archiving $VERSION ($BUILD · $COMMIT)"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUTPUT"

xcodebuild archive \
    -workspace Kadr.xcworkspace \
    -scheme Kadr \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    KADR_GIT_COMMIT="$COMMIT" \
    KADR_APPCAST_URL="$FEED_URL" \
    KADR_SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    -quiet

# ---------------------------------------------------------------- export
step "Exporting with Developer ID"
OPTIONS=$(mktemp -t kadr-export-options).plist
trap 'rm -f "$OPTIONS"' EXIT
sed "s/__KADR_TEAM_ID__/$TEAM_ID/" Distribution/ExportOptions.plist > "$OPTIONS"
grep -q "__KADR_TEAM_ID__" "$OPTIONS" && fail "the team ID placeholder survived substitution"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$OPTIONS" \
    -quiet
[ -d "$APP" ] || fail "the export produced no Kadr.app"

# ---------------------------------------------------------------- verify
step "Verifying what the export produced"
plist="$APP/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

built_key=$(read_key SUPublicEDKey)
[ -n "$built_key" ] || fail "SUPublicEDKey is empty in the built Info.plist"
[[ "$built_key" == *'$('* || "$built_key" == *PLACEHOLDER* ]] && fail "SUPublicEDKey is a placeholder: $built_key"
built_feed=$(read_key SUFeedURL)
[ -n "$built_feed" ] || fail "SUFeedURL is empty in the built Info.plist"
[[ "$built_feed" == *'$('* ]] && fail "SUFeedURL is an unexpanded placeholder: $built_feed"
[ "$(read_key CFBundleVersion)" = "$BUILD" ] || fail "CFBundleVersion is $(read_key CFBundleVersion), expected $BUILD"
[ "$(read_key KadrGitCommit)" = "$COMMIT" ] || fail "KadrGitCommit is '$(read_key KadrGitCommit)', expected $COMMIT"
note "Info.plist: feed $built_feed, key set, build $BUILD, commit $COMMIT"

entitlements=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
for entitlement in com.apple.security.device.camera com.apple.security.device.audio-input; do
    grep -q "$entitlement" <<<"$entitlements" \
        || fail "$entitlement is missing from the signed app — the hardened runtime would deny it"
done
note "camera and microphone entitlements present"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
    || fail "Kadr.app is not signed with Developer ID"

# ---------------------------------------------------------------- symbols
# A tester's .ips report is unreadable without the dSYMs of that exact build (T-REL-6).
step "Keeping symbols in $SYMBOLS"
rm -rf "$SYMBOLS"
mkdir -p "$SYMBOLS"
cp -R "$ARCHIVE" "$SYMBOLS/"
if [ -d "$ARCHIVE/dSYMs" ]; then
    find "$ARCHIVE/dSYMs" -name '*.dSYM' -maxdepth 1 -print0 \
        | xargs -0 -I{} dwarfdump --uuid {} > "$SYMBOLS/uuids.txt"
else
    fail "the archive has no dSYMs — check DEBUG_INFORMATION_FORMAT for Release"
fi
note "$(wc -l < "$SYMBOLS/uuids.txt" | tr -d ' ') UUIDs recorded"

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

IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$IDENTITY" ] || fail "no Developer ID Application identity for team $TEAM_ID"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# ---------------------------------------------------------------- notarize
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "Notarizing"
    result=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json) || true
    status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$result" 2>/dev/null || true)
    submission=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$result" 2>/dev/null || true)
    if [ "$status" != "Accepted" ]; then
        printf '%s\n' "$result" >&2
        [ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" >&2
        fail "notarization returned '${status:-no status}'"
    fi
    # Stapling is what lets the DMG open on a Mac that is offline.
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    # Gatekeeper's own verdict, on the app as a tester's Mac will see it.
    mount=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$DMG" >/dev/null
    spctl -a -vvv -t exec "$mount/Kadr.app" || { hdiutil detach "$mount" >/dev/null; fail "Gatekeeper rejects the app"; }
    hdiutil detach "$mount" >/dev/null
else
    note "skipping notarization — the result will not open on another Mac"
fi

# ---------------------------------------------------------------- appcast
step "Signing for Sparkle and updating the appcast"
SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" build -name sign_update -type f 2>/dev/null | head -1)
[ -n "$SIGN_UPDATE" ] || fail "Sparkle's sign_update was not found — build once so its tools land in DerivedData"
SIGNATURE_OUTPUT=$("$SIGN_UPDATE" "$DMG")
[[ "$SIGNATURE_OUTPUT" == *edSignature* ]] || fail "sign_update produced no signature: $SIGNATURE_OUTPUT"
Scripts/update-appcast.sh \
    --version "$VERSION" \
    --build "$BUILD" \
    --dmg "$DMG" \
    --tag "$TAG" \
    --channel "$CHANNEL" \
    --appcast "$APPCAST" \
    --signature-line "$SIGNATURE_OUTPUT"

# ---------------------------------------------------------------- cask
step "Updating the Homebrew cask"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' \
    -e "s/^  version \".*\"/  version \"$VERSION,$BUILD\"/" \
    -e "s/^  sha256 .*/  sha256 \"$SHA\"/" \
    Distribution/kadr.rb
note "kadr.rb → $VERSION, $SHA"

step "Done"
note "$DMG"
note "symbols: $SYMBOLS"
note "next: git tag $TAG, publish the DMG under that tag, then commit appcast.xml and Distribution/kadr.rb"
