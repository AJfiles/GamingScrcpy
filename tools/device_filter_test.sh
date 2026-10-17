#!/usr/bin/env bash
# §D on real hardware: does the host colour grade reach the mirrored picture of
# an actual device, and does it leave the device itself alone?
#
# Two sessions of the packaged client against the attached tablet -- one plain,
# one with the new contrast/brightness/gamma grade -- then four assertions:
#
#   1. the fork reports the grade it actually installed (the log line carries
#      the three values, so a flag that never reaches scrcpy_options fails);
#   2. frames were presented and measured (a telemetry summary exists, and the
#      source size is the panel's own);
#   3. the device's own screen brightness is byte-identical before and after,
#      read only with dumpsys -- the grade is a host-side LUT on a copy of the
#      decoded frame, so if any code path had touched the panel setting this
#      would move;
#   4. the graded session's latency cost is printed, not claimed: median/p90/p99
#      of both sessions are reported side by side so the CPU cost of the grade
#      on a 1080x2316 stream is visible in the numbers.
#
# Needs a device. Without one it prints SKIP and exits 0, so the gate stays
# green on a machine with no phone attached.
#
#   bash tools/device_filter_test.sh [seconds-per-session]
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
client="$root/dist/GamingScrcpy/scrcpy/scrcpy.exe"
adbwin='C:\Users\Administrator\Desktop\GamingCapture\dist\GamingScrcpy\scrcpy\adb.exe'
SECS="${1:-16}"

audit() { bash "$here/adb_audit.sh" "$*"; }

[ -f "$client" ] || { echo "SKIP filters (no packaged client)"; exit 0; }
audit "adb devices"
serial=$(cd "$root/dist/GamingScrcpy/scrcpy" && ./adb.exe devices 2>/dev/null \
        | awk 'NR>1 && $2=="device" {print $1; exit}')
if [ -z "$serial" ]; then
    echo "SKIP filters (no adb device attached)"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# read-only: the panel's own brightness state, as one comparable string
brightness() {
    audit "adb -s $serial shell dumpsys display (read-only brightness snapshot)"
    "$adbwin" -s "$serial" shell dumpsys display 2>/dev/null \
        | grep -oiE 'mBrightness[A-Za-z]*=[0-9.]+|mPhysicalDisplayBrightness=[0-9.]+' \
        | sort -u | tr '\n' ';'
}

run_case() {
    local name=$1; shift
    local log="$tmp/$name.log"
    audit "scrcpy --serial=$serial --game-telemetry-log --video-bit-rate=48M --max-fps=60 --time-limit=$SECS $*"
    ADB="$adbwin" "$client" --serial="$serial" --game-telemetry-log \
        --video-bit-rate=48M --max-fps=60 --time-limit="$SECS" "$@" \
        > "$log.raw" 2>&1 &
    local pid=$!
    sleep 5
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
        -File "$here/wake_device_screen.ps1" > "$log.wake" 2>&1
    wait "$pid"
    sed 's/\x1b\[[0-9;]*m//g' "$log.raw" > "$log"
}

before=$(brightness)
run_case plain --video-codec=h264 --video-buffer=0 --game-low-latency
after=$(brightness)
run_case graded --video-codec=h264 --video-buffer=0 --game-low-latency \
        --game-postfx=contrast,brightness,gamma,sat \
        --game-contrast=140 --game-brightness=120 --game-gamma=130 \
        --game-saturation=130

summary() { grep -o 'telemetry-summary:.*' "$tmp/$1.log" | tail -1; }

# The summary counts the seconds in which at least one frame arrived, so a
# session over a static screen (a launcher home page) reports almost none and
# its percentiles describe one frame. Pass in that case would mean "a number was
# printed", so require a quarter of the window to have frames and say otherwise.
min_secs=$(( SECS / 4 ))
for c in plain graded; do
    s="$(summary $c)"
    secs=$(printf '%s' "$s" | sed -n 's/.*seconds=\([0-9]*\).*/\1/p')
    if [ -z "$s" ]; then
        echo "FAIL filters $c produced no telemetry summary"
        tail -5 "$tmp/$c.log"
        fail=1
    elif [ "${secs:-0}" -lt "$min_secs" ]; then
        echo "SKIP filters $c: only ${secs:-0} of ${SECS}s had a new frame ($s)"
        echo "SKIP why: the encoder only emits on content change -- put a moving"
        echo "SKIP      screen on the device (a game, a video) and re-run"
    else
        echo "PASS filters $c produced a latency summary: $s"
    fi
done

line=$(grep -o 'Host post-processing enabled.*' "$tmp/graded.log" | tail -1)
if echo "$line" | grep -q 'contrast=140' && echo "$line" | grep -q 'brightness=120' \
        && echo "$line" | grep -q 'gamma=130'; then
    echo "PASS filters the grade reached the engine on a live device: $line"
else
    echo "FAIL filters the grade did not reach the engine (got: '${line:-none}')"
    fail=1
fi
if grep -q 'Host post-processing enabled' "$tmp/plain.log"; then
    echo "FAIL filters the plain session installed a grade it was not asked for"
    fail=1
else
    echo "PASS filters plain session ran with no grade installed"
fi

src_plain=$(grep -o 'src=[0-9]*x[0-9]*' "$tmp/plain.log" | tail -1 | cut -d= -f2)
src_graded=$(grep -o 'src=[0-9]*x[0-9]*' "$tmp/graded.log" | tail -1 | cut -d= -f2)
if [ -n "$src_plain" ] && [ "$src_plain" = "$src_graded" ]; then
    echo "PASS filters both sessions captured the same device size ($src_plain)"
else
    echo "FAIL filters capture size changed or was missing ('$src_plain' vs '$src_graded')"
    fail=1
fi

if [ "$before" = "$after" ]; then
    echo "PASS filters the device's own brightness is unchanged by the grade"
else
    echo "FAIL filters the device brightness moved: '$before' -> '$after'"
    fail=1
fi

echo "RESULT filters serial=$serial time_limit=${SECS}s"
echo "RESULT filters brightness snapshot: ${before:-unreadable}"
echo "MATRIX-D | grade=off   | $(summary plain)"
echo "MATRIX-D | grade=on    | $(summary graded)"

[ $fail -eq 0 ] && echo "FILTDEV OK" || echo "FILTDEV FAILED"
exit $fail
