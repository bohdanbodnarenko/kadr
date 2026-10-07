#!/bin/bash
#
# Runs a command, and if it is still running after LIMIT seconds, samples the test
# processes it started, prints where every thread is waiting, and fails.
#
# CI's package jobs hung twice for six hours with no output at all (StudioRender and
# VisionServices), and a cancelled job keeps no record of where it stopped. A hang that
# fails after a few minutes with stacks is one somebody can fix.
#
# Usage: Scripts/watchdog.sh LIMIT_SECONDS command [args…]
set -uo pipefail

LIMIT="${1:?usage: watchdog.sh LIMIT_SECONDS command [args…]}"
shift

"$@" &
PID=$!

ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
    if [ "$ELAPSED" -ge "$LIMIT" ]; then
        echo "::error::still running after ${LIMIT}s — sampling the test processes" >&2
        for proc in $(pgrep -f 'swiftpm-testing-helper|xctest|\.xctest/Contents/MacOS'); do
            echo "===== sample of pid $proc: $(ps -o command= -p "$proc" | cut -c1-160)" >&2
            # Keep the frames that say where each thread is: Kadr's own code and the
            # system call it is blocked in.
            sample "$proc" 3 2>/dev/null \
                | grep -E 'Thread_|DispatchQueue|Kadr|Annotation|Studio|Vision|Speech|Shared|Test|semaphore|_wait|XPC|lock' \
                | sed 's/ (in .*)//' | awk '{$1=$1};1' | uniq | head -120 >&2
        done
        pkill -TERM -P "$PID" 2>/dev/null
        kill -TERM "$PID" 2>/dev/null
        sleep 5
        pkill -KILL -f 'swiftpm-testing-helper|xctest' 2>/dev/null
        exit 124
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
done

wait "$PID"
