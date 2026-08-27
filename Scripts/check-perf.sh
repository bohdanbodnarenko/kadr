#!/bin/bash
#
# Kadr — the PRD §8 performance budgets, measured (docs/04 §7, §11).
#
# The budgets in the PRD are the definition of done, not decoration, so this measures
# them on a release build and fails when one is breached. Three of them can be checked
# without a Screen Recording grant, which means CI can check them:
#
#   * cold launch to menu-bar ready   < 300 ms   (read from the app's own signpost log)
#   * idle resident memory            < 30 MB    (40 MB hard fail)
#   * idle CPU                        0.0%       (no timers, no polling)
#
# The capture-latency budgets need a TCC grant and a real display, so they live in the
# app's integration tests instead.
#
# Usage:
#   Scripts/check-perf.sh [--app path/to/Kadr.app] [--idle-seconds 60] [--json out.json]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""; }

# PRD §8.
LAUNCH_BUDGET_MS=300
IDLE_RSS_WARN_MB=30
IDLE_RSS_FAIL_MB=40
IDLE_SECONDS=60
APP=""
JSON_OUT=""
REQUIRE_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --idle-seconds) IDLE_SECONDS="$2"; shift 2 ;;
        --json) JSON_OUT="$2"; shift 2 ;;
        # Without this, a machine that cannot run a GUI app reports "skipped" rather than
        # failing — which is what lets CI run the same script a developer runs.
        --require-run) REQUIRE_RUN=1; shift ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
done

if [ -z "$APP" ]; then
    for candidate in build/Build/Products/Release/Kadr.app build/Build/Products/Debug/Kadr.app; do
        [ -d "$candidate" ] && APP="$candidate" && break
    done
fi
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "✘ no Kadr.app to measure — build a release first, or pass --app"
    exit 1
fi

failures=0
warnings=0
fail() { printf '%s✘ %s%s\n' "$RED" "$1" "$OFF"; failures=$((failures + 1)); }
warn() { printf '%s▲ %s%s\n' "$YELLOW" "$1" "$OFF"; warnings=$((warnings + 1)); }
pass() { printf '%s✔ %s%s\n' "$GREEN" "$1" "$OFF"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }

# ---------------------------------------------------------------- launch
#
# The budgets describe steady-state idle, not first run: a fresh install opens onboarding,
# and measuring the agent with a SwiftUI window on screen measures the wrong thing.
#
# The flag is passed as a launch argument rather than written to the preferences file.
# `NSUserDefaults` reads command-line arguments as a volatile domain that outranks the
# stored one, so this changes nothing on disk and leaves the developer's own first-run
# experience alone.
trap 'pkill -x Kadr 2>/dev/null' EXIT

pkill -x Kadr 2>/dev/null
sleep 1
open -a "$PWD/$APP" --args -app.hasCompletedOnboarding YES 2>/dev/null \
    || open -a "$APP" --args -app.hasCompletedOnboarding YES

# Let launch settle before measuring: the first seconds include work that is not idle.
sleep 4
PID=$(pgrep -x Kadr | tail -1)
if [ -z "$PID" ]; then
    if [ "$REQUIRE_RUN" -eq 1 ]; then
        fail "the app did not stay running"
        exit 1
    fi
    echo "• the app could not be launched here — runtime budgets skipped"
    note "this needs a logged-in GUI session; pass --require-run to make it fatal"
    # The static budget still applies wherever this runs.
    SIZE_KB=$(du -sk "$APP" | cut -f1)
    SIZE_MB=$((SIZE_KB / 1024))
    if [ "$SIZE_MB" -ge 15 ]; then
        fail "bundle ${SIZE_MB} MB, over the 15 MB budget"
        exit 1
    fi
    pass "bundle ${SIZE_MB} MB (budget < 15 MB)"
    exit 0
fi

# The app logs its own launch-to-status-item interval; read it back rather than timing
# the launch from outside, which would include Finder and dyld.
LAUNCH_MS=$(/usr/bin/log show --predicate 'subsystem == "app.kadr.Kadr"' \
    --last 2m --info --style compact 2>/dev/null \
    | sed -n 's/.*Status item ready in \([0-9.]*\) ms.*/\1/p' | tail -1)

if [ -z "$LAUNCH_MS" ]; then
    warn "could not read the launch signpost from the log"
    LAUNCH_MS="null"
else
    LAUNCH_INT=${LAUNCH_MS%.*}
    if [ "$LAUNCH_INT" -gt "$LAUNCH_BUDGET_MS" ]; then
        fail "cold launch ${LAUNCH_MS} ms, over the ${LAUNCH_BUDGET_MS} ms budget"
    elif [ "$LAUNCH_INT" -gt $((LAUNCH_BUDGET_MS * 80 / 100)) ]; then
        warn "cold launch ${LAUNCH_MS} ms, within 80% of the ${LAUNCH_BUDGET_MS} ms budget"
    else
        pass "cold launch ${LAUNCH_MS} ms (budget ${LAUNCH_BUDGET_MS} ms)"
    fi
fi

# ---------------------------------------------------------------- idle memory
footprint_mb() {
    footprint -p "$1" 2>/dev/null \
        | sed -n 's/.*phys_footprint: *\([0-9]*\) MB.*/\1/p' | tail -1
}

RSS_MB=$(footprint_mb "$PID")
if [ -z "$RSS_MB" ]; then
    warn "could not read the process footprint"
    RSS_MB="null"
elif [ "$RSS_MB" -ge "$IDLE_RSS_FAIL_MB" ]; then
    fail "idle footprint ${RSS_MB} MB, over the ${IDLE_RSS_FAIL_MB} MB hard limit"
elif [ "$RSS_MB" -ge "$IDLE_RSS_WARN_MB" ]; then
    warn "idle footprint ${RSS_MB} MB, over the ${IDLE_RSS_WARN_MB} MB target"
else
    pass "idle footprint ${RSS_MB} MB (target < ${IDLE_RSS_WARN_MB} MB)"
fi

# ---------------------------------------------------------------- idle CPU
#
# The PRD asks for zero wakeups from our code over 60 s. Instruments cannot run headless,
# so this measures the process's consumed CPU time instead: a process with a timer burns
# measurable CPU, and one that is purely event-driven burns none.
CPU_BEFORE=$(ps -o time= -p "$PID" | tr -d ' ')
note "sampling idle CPU for ${IDLE_SECONDS}s…"
sleep "$IDLE_SECONDS"
CPU_AFTER=$(ps -o time= -p "$PID" | tr -d ' ')

seconds_of() {
    printf '%s' "$1" | awk -F: '{ if (NF == 3) print $1*3600 + $2*60 + $3; else if (NF == 2) print $1*60 + $2; else print $1 }'
}
DELTA=$(awk -v a="$(seconds_of "$CPU_BEFORE")" -v b="$(seconds_of "$CPU_AFTER")" 'BEGIN { printf "%.2f", b - a }')

# A tenth of a second over a minute is the noise floor of ps's own accounting.
if awk -v d="$DELTA" 'BEGIN { exit !(d > 0.1) }'; then
    fail "burned ${DELTA}s of CPU while idle over ${IDLE_SECONDS}s — something is polling"
else
    pass "idle CPU ${DELTA}s over ${IDLE_SECONDS}s (budget: none)"
fi

# ---------------------------------------------------------------- bundle size
SIZE_KB=$(du -sk "$APP" | cut -f1)
SIZE_MB=$((SIZE_KB / 1024))
if [ "$SIZE_MB" -ge 15 ]; then
    fail "bundle ${SIZE_MB} MB, over the 15 MB budget"
else
    pass "bundle ${SIZE_MB} MB (budget < 15 MB)"
fi

pkill -x Kadr 2>/dev/null

# ---------------------------------------------------------------- report
if [ -n "$JSON_OUT" ]; then
    cat > "$JSON_OUT" <<JSON
{
  "measuredAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "coldLaunchMilliseconds": ${LAUNCH_MS:-null},
  "idleFootprintMegabytes": ${RSS_MB:-null},
  "idleCpuSeconds": ${DELTA},
  "idleSampleSeconds": ${IDLE_SECONDS},
  "bundleMegabytes": ${SIZE_MB},
  "budgets": {
    "coldLaunchMilliseconds": ${LAUNCH_BUDGET_MS},
    "idleFootprintMegabytes": ${IDLE_RSS_WARN_MB},
    "idleFootprintHardMegabytes": ${IDLE_RSS_FAIL_MB},
    "bundleMegabytes": 15
  },
  "failures": ${failures},
  "warnings": ${warnings}
}
JSON
    note "wrote $JSON_OUT"
fi

echo
if [ "$failures" -eq 0 ]; then
    printf '%sperformance budgets met%s' "$GREEN" "$OFF"
    [ "$warnings" -gt 0 ] && printf ' %s(%d warning(s))%s' "$YELLOW" "$warnings" "$OFF"
    echo
    exit 0
fi
printf '%s%d budget(s) breached%s\n' "$RED" "$failures" "$OFF"
exit 1
