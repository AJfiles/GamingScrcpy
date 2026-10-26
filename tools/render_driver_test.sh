#!/usr/bin/env bash
# Presentation sweep: run the whole host presentation path (low-latency flag,
# borderless fullscreen, window filter, OSD telemetry, frame bridge) on every GPU
# backend the fork's --render-driver accepts, and assert the backend actually
# created is the one that was requested.
#
# Why this needs no phone: gamingdemo drives the same sc_gaming code as the
# mirror window, on a real window with real frames. The claim under test is not
# throughput (the demo paces its own presents) but that the presentation path
# works on each backend and that SDL never silently substitutes another one --
# which is what would make a documented --render-driver=vulkan profile a lie.
#
#   bash tools/render_driver_test.sh [frames]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMES="${1:-45}"

. "$ROOT/tools/layout.sh"
[ -n "$DEMO" ] || { echo "FAIL gamingdemo not found (build tree or package; layout=$LAYOUT)"; exit 1; }

WINSIZE=1920x1080
SRC=480x800
SW="${SRC%x*}"
SH="${SRC#*x}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail=0
for driver in direct3d11 opengl vulkan default; do
    hint=""
    [ "$driver" = default ] || hint="--driver=$driver"
    log="$T/$driver.log"
    if ! "$DEMO" --frames="$FRAMES" --width="$SW" --height="$SH" \
            --win-size="$WINSIZE" $hint --bridge="$T/$driver.raw" --no-osd \
            > "$log" 2>&1; then
        # a machine without the backend is a fact about the machine, not a
        # regression in the fork
        if grep -qi 'matching render driver\|CreateRenderer failed' "$log"; then
            echo "RESULT $driver unavailable-on-this-host"
        else
            echo "RESULT $driver FAILED"
            tail -4 "$log" | sed 's/^/        /'
            fail=1
        fi
        continue
    fi
    grep -q 'gamingdemo: PASS' "$log" || { echo "RESULT $driver no-PASS"; fail=1; continue; }
    backend="$(sed -n 's/.*renderer backend: \([a-z0-9]*\).*/\1/p' "$log" | head -1)"
    presented="$(sed -n 's/.*gamingdemo: \([0-9]*\) frames.*/\1/p' "$log" | head -1)"
    # the bridge is the frame source OBS sees: whole RGBA frames of the source
    # size, and never more of them than the window presented (the fork's max-fps
    # limiter may drop a frame from the bridge that the window still showed)
    frame_bytes=$(( SW * SH * 4 ))
    bytes=0
    [ -f "$T/$driver.raw" ] && bytes="$(wc -c < "$T/$driver.raw")"
    bridged=$(( bytes / frame_bytes ))
    if [ "$backend" != "${driver/default/direct3d11}" ]; then
        echo "RESULT $driver silently-substituted-by=${backend:-none}"
        fail=1
    elif [ "$presented" != "$FRAMES" ]; then
        echo "RESULT $driver presented=${presented:-0}/$FRAMES"
        fail=1
    elif [ "$bytes" -le 0 ] || [ $(( bytes % frame_bytes )) -ne 0 ] \
            || [ "$bridged" -gt "$presented" ]; then
        echo "RESULT $driver bad bridge: ${bytes}B (${bridged} frames, presented=$presented)"
        fail=1
    else
        echo "RESULT $driver backend=$backend presented=$presented/$FRAMES bridged=$bridged window=$WINSIZE"
    fi
done

[ "$fail" -eq 0 ] && echo OK
exit $fail
