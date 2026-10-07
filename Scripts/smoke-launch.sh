#!/bin/bash
#
# Launches the agent and the editor and checks they are still running a few seconds later.
#
# For the oldest supported macOS. CI builds on the newest SDK, and a symbol from a newer
# release linked as required makes dyld refuse to start the app there: Kadr shipped one
# (SCScreenshotConfiguration, macOS 26) that crashed every launch on macOS 14 and 15.
# Unit tests cannot cover this on macOS 14 — its newest Xcode is too old to load a test
# bundle built with the current Swift Testing — so the check is the launch itself.
#
# Usage: Scripts/smoke-launch.sh [path/to/Kadr.app] [seconds]
set -uo pipefail

APP="${1:-build/Build/Products/Debug/Kadr.app}"
SECONDS_ALIVE="${2:-10}"
EDITOR="$APP/Contents/Applications/KadrEditor.app"

failures=0

check() {
    local label="$1" binary="$2"
    shift 2
    if [ ! -x "$binary" ]; then
        echo "✘ $label: no executable at $binary"
        failures=$((failures + 1))
        return
    fi
    "$binary" "$@" >/tmp/smoke-"$label".log 2>&1 &
    local pid=$!
    sleep "$SECONDS_ALIVE"
    if kill -0 "$pid" 2>/dev/null; then
        echo "✔ $label is running after ${SECONDS_ALIVE}s on macOS $(sw_vers -productVersion)"
        kill -TERM "$pid" 2>/dev/null
        sleep 1
        kill -KILL "$pid" 2>/dev/null
    else
        wait "$pid"
        echo "✘ $label exited within ${SECONDS_ALIVE}s (status $?) on macOS $(sw_vers -productVersion)"
        tail -20 /tmp/smoke-"$label".log
        for report in ~/Library/Logs/DiagnosticReports/"$label"*.ips; do
            [ -e "$report" ] || continue
            grep -oE '"(indicator|reasons)":[^]]{0,600}' "$report" | head -4
        done
        failures=$((failures + 1))
    fi
}

check Kadr "$APP/Contents/MacOS/Kadr"
# The editor waits for a document when launched with none, which is enough to prove it
# loaded every library it links.
check KadrEditor "$EDITOR/Contents/MacOS/KadrEditor" -KadrUITesting

exit "$failures"
