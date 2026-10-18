#!/usr/bin/env bash
# v4 §6.1: the S23 Ultra validation matrix, as one measurable run.
#
# "se ve" is not a human judgement here: the fork prints one 'telemetry:' line
# per second of *presented* video, so an arm that paints reports lines and one
# that leaves the user a grey window reports none. Audio arms are measured the
# same way (a_kbps>0 in the telemetry line means encoded audio reached the
# client) and the PCM tap is measured in bytes received on the named pipe.
#
# Each arm runs for $RUN seconds (default 10) against the attached device.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$root/dist/GamingScrcpy/scrcpy/scrcpy.exe
adb=$root/dist/GamingScrcpy/scrcpy/adb.exe
out=${OUT:-$root/out/s23}
serial=${SERIAL:-}
run=${RUN:-10}
mkdir -p "$out"
export PATH="/c/msys64/ucrt64/bin:$root/dist/GamingScrcpy/scrcpy:$PATH"

if [ ! -f "$exe" ]; then echo "SKIP  no scrcpy.exe"; exit 2; fi
if [ -z "$serial" ] && [ -f "$adb" ]; then
    serial=$("$adb" devices 2>/dev/null | sed -n 's/^\([[:graph:]]*\)[[:space:]]*device$/\1/p' | head -1)
fi
[ -n "$serial" ] || { echo "SKIP  no device attached"; exit 2; }

arm() { # label  flags...
    local lbl=$1; shift
    local log=$out/$(echo "$lbl" | tr -c 'a-zA-Z0-9' '_').txt
    taskkill //F //IM scrcpy.exe >/dev/null 2>&1; sleep 1
    "$exe" --serial="$serial" --game-telemetry-log "$@" > "$log" 2>&1 &
    sleep "$run"
    taskkill //F //IM scrcpy.exe >/dev/null 2>&1
    wait 2>/dev/null
    local tel=$(grep -c 'telemetry:' "$log")
    local aud=$(grep -o 'a_kbps=[0-9]*' "$log" | sed -n 's/a_kbps=//p' | sort -rn | head -1)
    local err=$(grep -c '^ERROR' "$log")
    printf 'ARM %-26s telemetry=%s a_kbps_max=%s errors=%s\n' \
        "$lbl" "$tel" "${aud:-0}" "$err"
}

arm h264-d3d11      --video-codec=h264 --render-driver=direct3d11
arm h265-d3d11      --video-codec=h265 --render-driver=direct3d11
arm av1-d3d11       --video-codec=av1  --render-driver=direct3d11
arm opengl          --video-codec=h264 --render-driver=opengl
arm vulkan          --video-codec=h264 --render-driver=vulkan
arm audio-opus      --video-codec=h264 --audio-codec=opus
arm audio-raw       --video-codec=h264 --audio-codec=raw
arm filter-panel    --video-codec=h264 --game-filter-overlay
arm lowlat-120      --video-codec=h264 --max-fps=120 --game-low-latency

# the PCM tap: bytes must arrive on the named pipe while the mirror runs.
# --audio-codec=raw because the tap decodes what the device sends, and the opus
# arm measured a_kbps=0 on this unit: with opus the tap had nothing to write.
# The probe counts the bytes Read() actually returned (tools/pcm_pipe_probe.ps1);
# the first version added a fixed 65536 per call and could invent a pass.
tap="$out/pcm_bytes.txt"
rm -f "$tap"
( powershell -NoProfile -ExecutionPolicy Bypass -File "$root/tools/pcm_pipe_probe.ps1" \
    > "$tap" 2>/dev/null ) &
"$exe" --serial="$serial" --video-codec=h264 --audio-codec=raw \
    --game-audio-pcm='\\.\pipe\gsc_pcm_probe' > "$out/pcm.log" 2>&1 &
sleep $((run + 2))
taskkill //F //IM scrcpy.exe >/dev/null 2>&1
wait 2>/dev/null
printf 'ARM %-26s pcm_bytes=%s\n' audio-pcm-tap "$(tr -d '[:space:]' < "$tap")"
