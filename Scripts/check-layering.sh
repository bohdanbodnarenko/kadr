#!/bin/bash
#
# Kadr — architectural guardrails (docs/04-swift-architecture.md §2 and §11).
#
# Three checks, all static:
#   A. Zero network. No networking imports or symbols anywhere except the Sparkle
#      integration — this is what makes the PRD §4 "no upload surface exists"
#      promise machine-verified rather than a README claim.
#   B. The agent app target never links EditorUI, VisionServices, StudioRender or
#      AnnotationRender. Those live in the editor so their RAM dies with that
#      process (docs/04 §1, §7.4, docs/10 R2.1).
#   C. The built agent binary links no networking framework — docs/03 §9 asks for
#      exactly this grep over the linked frameworks. Skipped when nothing is built.
#      It also must not list Speech, CoreImage, VideoToolbox or Vision.
#   D. No legacy CoreGraphics screen capture. ScreenCaptureKit is the only capture
#      path (docs/04 §4.2, §12): the CGWindowList/CGDisplay family is deprecated and
#      triggers extra TCC alerts on Sonoma and later.
#   E. The pure packages import no UI framework. Doc 04 §2 says AnnotationModel has
#      "No AppKit"; the same holds for Shared. A model that reaches for a view type
#      cannot be tested headlessly or reused by the Rust core doc 05 contemplates.
#   F. Package dependencies respect the layering: a package may only depend on
#      packages in a strictly lower layer, per the module list in docs/04 §2.
#
# Usage: Scripts/check-layering.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

failures=0
fail() { printf '%s✘ %s%s\n' "$RED" "$1" "$OFF"; failures=$((failures + 1)); }
pass() { printf '%s✔ %s%s\n' "$GREEN" "$1" "$OFF"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }

# Swift sources we own, across every process in the app family — the agent, the editor,
# the XPC helper and the `kadr` CLI. Sparkle's own sources (once vendored) are never in
# these paths.
swift_sources() {
    find Kadr KadrTests KadrEditor HelperTools KadrCLI Packages/*/Sources Packages/*/Tests \
        -name '*.swift' -not -path '*/.build/*' 2>/dev/null | sort
}

# The one place networking code is allowed to live (docs/04 §10, PRD §9).
# Nothing lives here yet; it is created in M11 when Sparkle is integrated.
SPARKLE_PATHS='^Kadr/Updates/'

# ---------------------------------------------------------------- A. zero network
NETWORK_SYMBOLS='import Network|import NetworkExtension|import CFNetwork|URLSession|NSURLConnection|NSURLSession|URLRequest|NWConnection|NWListener|NWBrowser|CFSocket|CFStream|Socket\(|getaddrinfo|CFHTTP'

net_hits=""
while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
        Kadr/Updates/*) continue ;;
    esac
    hit=$(grep -nE "$NETWORK_SYMBOLS" "$file" 2>/dev/null)
    [ -n "$hit" ] && net_hits="${net_hits}${file}: ${hit}"$'\n'
done <<< "$(swift_sources)"

if [ -n "$net_hits" ]; then
    fail "networking code found outside the Sparkle integration ($SPARKLE_PATHS)"
    printf '%s' "$net_hits" | sed 's/^/    /'
else
    pass "zero network: no networking imports or symbols outside the Sparkle integration"
fi

# ---------------------------------------------------------------- B. agent linkage
PBXPROJ=Kadr.xcodeproj/project.pbxproj
FORBIDDEN_IN_AGENT="EditorUI VisionServices StudioRender AnnotationRender"

if [ ! -f "$PBXPROJ" ]; then
    fail "Kadr.xcodeproj/project.pbxproj is missing — cannot verify agent linkage (docs/10 R2.7)"
else
    # Products linked by the *agent* target specifically. Scoped rather than searched across
    # the whole project, because KadrEditor legitimately links EditorUI — the rule is about
    # what the resident process drags in, not about the workspace.
    linked=$(awk '
        /^\t\t[A-F0-9]+ \/\* Kadr \*\/ = \{/ { inTarget = 1 }
        inTarget && /packageProductDependencies = \(/ { inList = 1; next }
        inList && /\);/ { inList = 0; inTarget = 0 }
        inList { print }
    ' "$PBXPROJ" | sed -n 's|.*/\* \([A-Za-z]*\) \*/,|\1|p' | sort -u)

    for module in $FORBIDDEN_IN_AGENT; do
        if printf '%s\n' "$linked" | grep -qx "$module"; then
            fail "$module is linked into the agent app target (docs/04 §1: it must not be)"
        elif grep -rqE "^\s*(@testable )?import $module\b" Kadr KadrTests 2>/dev/null; then
            fail "$module is imported by the agent app sources (docs/04 §1: it must not be)"
        else
            pass "agent app target does not link or import $module"
        fi
    done
fi

# ---------------------------------------------------------------- B2. legacy capture APIs
LEGACY_CAPTURE='CGWindowListCreateImage|CGWindowListCreateImageFromArray|CGDisplayCreateImage|CGDisplayCreateImageForRect|CGWindowListCreateDescriptionFromArray'

legacy_hits=""
while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Comments naming the banned APIs (including this rule's own documentation)
    # are not calls to them.
    hit=$(grep -nE "$LEGACY_CAPTURE" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)')
    [ -n "$hit" ] && legacy_hits="${legacy_hits}${file}: ${hit}"$'\n'
done <<< "$(swift_sources)"

if [ -n "$legacy_hits" ]; then
    fail "legacy CoreGraphics capture API used — ScreenCaptureKit only (docs/04 §4.2)"
    printf '%s' "$legacy_hits" | sed 's/^/    /'
else
    pass "all screen capture goes through ScreenCaptureKit"
fi

# ---------------------------------------------------------------- B3. pure packages
PURE_PACKAGES="Shared AnnotationModel"
UI_FRAMEWORKS='^import (AppKit|SwiftUI|UIKit|Cocoa)$'

for package in $PURE_PACKAGES; do
    hits=$(grep -rnE "$UI_FRAMEWORKS" "Packages/$package/Sources" 2>/dev/null)
    if [ -n "$hits" ]; then
        fail "$package imports a UI framework, but docs/04 §2 says it must not"
        printf '%s\n' "$hits" | sed 's/^/    /'
    else
        pass "$package imports no UI framework"
    fi
done

# ---------------------------------------------------------------- C. linked frameworks
# The source grep above cannot see what a dependency drags in; this can.
# Prefer the newest binary so a stale Release product cannot hide a Debug rebuild
# (docs/10 R2.7: the denylist is only as honest as the file it greps).
agent_binary=""
agent_mtime=0
consider() {
    local candidate="$1"
    [ -f "$candidate" ] || return 0
    local mtime
    mtime=$(stat -f %m "$candidate" 2>/dev/null || stat -c %Y "$candidate")
    if [ "$mtime" -ge "$agent_mtime" ]; then
        agent_mtime=$mtime
        agent_binary=$candidate
    fi
}
consider "build/Build/Products/Debug/Kadr.app/Contents/MacOS/Kadr"
consider "build/Build/Products/Release/Kadr.app/Contents/MacOS/Kadr"
if [ -z "$agent_binary" ]; then
    while IFS= read -r candidate; do
        consider "$candidate"
    done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -type f \
        -path '*/Build/Products/*/Kadr.app/Contents/MacOS/Kadr' 2>/dev/null)
fi

if [ -n "$agent_binary" ] && [ -f "$agent_binary" ]; then
    # Debug builds emit a stub `Kadr` that only links `Kadr.debug.dylib`. The frameworks
    # live on the dylib; grepping the stub would pass this denylist without proving anything.
    agent_image="$agent_binary"
    debug_dylib="$(dirname "$agent_binary")/$(basename "$agent_binary").debug.dylib"
    [ -f "$debug_dylib" ] && agent_image="$debug_dylib"

    linked_network=$(otool -L "$agent_image" | grep -iE '/(Network|CFNetwork|NetworkExtension)\.framework')
    if [ -n "$linked_network" ]; then
        fail "the agent binary links a networking framework"
        printf '%s\n' "$linked_network" | sed 's/^/    /'
    else
        pass "agent binary links no networking framework"
        note "checked $agent_image"
    fi

    denied=$(otool -L "$agent_image" | grep -iE '/(Speech|CoreImage|VideoToolbox|Vision)\.framework' || true)
    if [ -n "$denied" ]; then
        fail "agent binary links Speech, CoreImage, VideoToolbox or Vision (docs/10 R2.1)"
        printf '%s\n' "$denied" | sed 's/^/    /'
    else
        pass "agent binary links no Speech/CoreImage/VideoToolbox/Vision"
    fi
else
    note "no built agent binary found — linked-framework check skipped"
fi

# ---------------------------------------------------------------- C. package layering
# Source of truth: docs/04 §2. Layer N may only depend on layers < N.
layer_of() {
    case "$1" in
        Shared) echo 0 ;;
        CaptureCore|OverlayKit|AnnotationModel|MediaExport|VisionServices|AutomationKit|SettingsKit|StudioSession) echo 1 ;;
        RecordingCore|SelectionUI|AnnotationRender|HistoryKit|StudioRender) echo 2 ;;
        EditorUI) echo 3 ;;
        *) echo "" ;;
    esac
}

for manifest in Packages/*/Package.swift; do
    package=$(basename "$(dirname "$manifest")")
    package_layer=$(layer_of "$package")
    if [ -z "$package_layer" ]; then
        fail "$package is not in the module list of docs/04 §2 — add it there first"
        continue
    fi

    # Declared edges (Package.swift) plus real edges (import statements) must agree.
    declared=$(sed -n 's|.*\.package(path: "\.\./\([A-Za-z]*\)").*|\1|p' "$manifest" | sort -u)
    imported=$(grep -rhE '^import [A-Za-z]+' "Packages/$package/Sources" 2>/dev/null \
        | sed 's/^import //' | sort -u)

    for dep in $declared; do
        dep_layer=$(layer_of "$dep")
        if [ -z "$dep_layer" ]; then
            fail "$package depends on unknown package $dep"
        elif [ "$dep_layer" -ge "$package_layer" ]; then
            fail "$package (layer $package_layer) depends on $dep (layer $dep_layer) — lower layers only"
        fi
    done

    for imp in $imported; do
        # Only our own packages are layered; system frameworks are not.
        if [ -n "$(layer_of "$imp")" ] && ! printf '%s\n' "$declared" | grep -qx "$imp"; then
            fail "$package imports $imp without declaring it in Package.swift"
        fi
    done
done
[ "$failures" -eq 0 ] && pass "package layering matches docs/04 §2"

# ---------------------------------------------------------------- G. tested-only public API (docs/10 R3.3)
if Scripts/check-dead-api.sh; then
    :
else
    fail "dead-API check failed (docs/10 R3.3)"
fi

# ----------------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
    printf '%slayering check passed%s\n' "$GREEN" "$OFF"
    exit 0
fi
printf '%s%d layering violation(s)%s\n' "$RED" "$failures" "$OFF"
note "The rules live in CLAUDE.md and docs/04-swift-architecture.md §2/§11."
exit 1
