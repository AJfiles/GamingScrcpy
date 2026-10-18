#!/usr/bin/env bash
# v4 §6.2/§6.3: the two S23 Ultra measurements the Motorola could not give.
#
#   * latency: gate §12's number, re-measured on a 2023 flagship encoder
#   * audio:   "suena en PC" decided by signal level, not by a_kbps
#
# a_kbps>0 only proves encoded bytes arrived. The claim the directive makes is
# that the user *hears* something, so each audio arm records a file and the file
# must contain an audio stream whose mean level is above digital silence.
#
# Exit: 0 measured, 2 SKIP (no device / no binaries), 1 a FAIL.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
out=${OUT:-$root/out/s23}
reps=${REPS:-3}
secs=${SECS:-12}
mkdir -p "$out"
export PATH="/c/msys64/ucrt64/bin:$root/dist/GamingScrcpy/scrcpy:$PATH"

exe=""
for c in "$root/workspace/scrcpy/build-usb/app/scrcpy.exe" \
         "$root/dist/GamingScrcpy/scrcpy/scrcpy.exe"; do
    # a client can only start a session if its server asset sits beside it, and
    # build-usb/app has none: the first version of this script picked the tree
    # exe and every arm "measured" 0 telemetry lines, 9 bogus FAILs from a
    # harness bug rather than a product one
    [ -f "$c" ] && [ -f "$(dirname "$c")/scrcpy-server" ] && { exe=$c; break; }
done
[ -n "$exe" ] || { echo "SKIP  no scrcpy.exe with a scrcpy-server beside it"; exit 2; }
command -v ffprobe >/dev/null || { echo "SKIP  ffprobe missing"; exit 2; }

adb="$root/dist/GamingScrcpy/scrcpy/adb.exe"
serial=${SERIAL:-}
[ -x "$adb" ] || adb=adb
if [ -z "$serial" ]; then
    serial=$("$adb" devices 2>/dev/null \
        | sed -n 's/^\([[:graph:]]*\)[[:space:]]*device$/\1/p' | head -1)
fi
[ -n "$serial" ] || { echo "SKIP  no device attached"; exit 2; }
printf 'device=%s exe=%s reps=%s secs=%s\n\n' "$serial" "$exe" "$reps" "$secs"

fails=0
kill_scrcpy() { taskkill //F //IM scrcpy.exe >/dev/null 2>&1; sleep 1; }
count_scrcpy() { tasklist //FI "IMAGENAME eq scrcpy.exe" //NH 2>/dev/null \
    | grep -ci 'scrcpy\.exe'; }
# Ask the window to close and wait: a hard kill stops the recorder before it has
# written the moov atom, which made the first version of this script report
# "no audio stream" for recordings that were really just truncated files.
stop_scrcpy() {
    taskkill //IM scrcpy.exe >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(count_scrcpy)" -eq 0 ] && return 0
        sleep 1
    done
    kill_scrcpy
}

# Preflight: one short session proves this harness can drive this device at all.
# Without it, a broken invocation produced nine per-arm FAILs that read like nine
# product bugs; fail once, loudly, with the client's own words.
kill_scrcpy
"$exe" --serial="$serial" --game-telemetry-log --video-codec=h264 \
    > "$out/preflight.txt" 2>&1 &
sleep 8
kill_scrcpy
wait 2>/dev/null
pre=$(grep -c 'telemetry:' "$out/preflight.txt")
if [ "$pre" -eq 0 ]; then
    printf 'ABORT  the preflight painted no frame, so every arm below would measure 0\n'
    sed -n '1,10p' "$out/preflight.txt"
    exit 1
fi
printf 'preflight ok (%s telemetry lines in 8 s)\n\n' "$pre"

# ---------- latency -----------------------------------------------------------
# percentiles over every telemetry sample of every rep, so a single lucky second
# cannot make an arm look good
stats() { # file
    local n med p95 max
    n=$(wc -l < "$1" | tr -d ' ')
    [ "$n" -gt 0 ] || { printf 'n=0 (no telemetry: the mirror never painted)'; return; }
    sort -n "$1" | awk -v n="$n" '
        { v[NR] = $1 }
        END {
            med = (n % 2) ? v[(n+1)/2] : (v[n/2] + v[n/2+1]) / 2
            i95 = int(n * 0.95 + 0.999); if (i95 > n) i95 = n
            printf "n=%d median=%d p95=%d max=%d", n, med, v[i95], v[n]
        }'
}

lat_arm() { # label flags...
    local lbl=$1; shift
    local all=$out/lat_$lbl.txt
    : > "$all"
    local fpsf=$out/lat_$lbl.fps
    : > "$fpsf"
    for r in $(seq 1 "$reps"); do
        kill_scrcpy
        local log=$out/lat_${lbl}_r$r.txt
        # no --max-size here: the arm has to be comparable with the Motorola
        # baseline in BUILD_REPORT §5.1n, which streamed at native resolution
        "$exe" --serial="$serial" --game-telemetry-log "$@" \
            > "$log" 2>&1 &
        sleep "$secs"
        stop_scrcpy
        wait 2>/dev/null
        grep -o 'lat=[0-9]\+' "$log" | sed 's/lat=//' >> "$all"
        grep -o 'fps=[0-9.]\+' "$log" | sed 's/fps=//' >> "$fpsf"
    done
    printf 'LAT %-22s %s fps_med=%s\n' "$lbl" "$(stats "$all")" \
        "$(sort -n "$fpsf" | awk '{v[NR]=$1} END{ if (NR==0) print "n/a"; \
            else printf "%d", (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2 }')"
    [ "$(wc -l < "$all" | tr -d ' ')" -gt 0 ] || { printf '  FAIL %s measured nothing\n' "$lbl"; fails=$((fails+1)); }
}

# the shipped default shape, the §3.2 low-latency shape, and h265 for reference
lat_arm h264-d3d11-default --video-codec=h264 --render-driver=direct3d11
lat_arm h264-lowlat-60     --video-codec=h264 --render-driver=direct3d11 \
                           --game-low-latency --max-fps=60 --video-bit-rate=30M
lat_arm h265-lowlat-60     --video-codec=h265 --render-driver=direct3d11 \
                           --game-low-latency --max-fps=60 --video-bit-rate=40M
lat_arm h264-lowlat-120    --video-codec=h264 --render-driver=direct3d11 \
                           --game-low-latency --max-fps=120 --video-bit-rate=40M
lat_arm h264-1080p-120     --video-codec=h264 --render-driver=direct3d11 \
                           --game-low-latency --max-size=1080 --max-fps=120 \
                           --video-bit-rate=25M

# ---------- audio -------------------------------------------------------------
# "suena" = an audio stream exists AND its mean level is above silence. Digital
# silence measures about -91 dB; anything the user can hear is far above -60.
aud_arm() { # codec
    local codec=$1
    # measured, not guessed: the client refuses raw audio in an MP4 container
    # ("Recording to MP4 container does not support RAW audio"), so the raw arm
    # records to MKV or it measures nothing.
    local ext=mp4
    [ "$codec" = raw ] && ext=mkv
    local rec=$out/aud_$codec.$ext
    rm -f "$rec"
    kill_scrcpy
    "$exe" --serial="$serial" --video-codec=h264 --audio-codec="$codec" \
        --record="$rec" > "$out/aud_$codec.log" 2>&1 &
    sleep "$secs"
    stop_scrcpy
    wait 2>/dev/null
    if [ ! -s "$rec" ]; then
        printf 'AUDIO %-8s FAIL no recording produced\n' "$codec"
        fails=$((fails+1)); return
    fi
    local streams acodec vol
    streams=$(ffprobe -hide_banner -v error -show_entries stream=codec_type \
              -of csv=p=0 "$rec" | tr '\n' ' ')
    acodec=$(ffprobe -hide_banner -v error -select_streams a:0 \
             -show_entries stream=codec_name -of csv=p=0 "$rec")
    vol=$(ffmpeg -hide_banner -v error -i "$rec" -af volumedetect -f null - 2>&1 \
          | sed -n 's/.*mean_volume: \(-[0-9.]*\) dB.*/\1/p' | head -1)
    [ -n "$vol" ] || vol=-91
    printf 'AUDIO %-8s streams=[%s] audio=%s mean_volume=%s dB\n' \
        "$codec" "$streams" "${acodec:-none}" "$vol"
    if [ -z "$acodec" ]; then
        printf '  FAIL %s: the recording has no audio stream\n' "$codec"
        fails=$((fails+1))
    elif awk -v v="$vol" 'BEGIN{ exit !(v < -60) }'; then
        printf '  FAIL %s: mean level %s dB is silence\n' "$codec" "$vol"
        fails=$((fails+1))
    fi
}

aud_arm opus
aud_arm raw

# ---------- PCM tap -----------------------------------------------------------
# The first three versions of this arm launched the client from bash with
# --game-audio-pcm='\\.\pipe\...' and read the tap with a NamedPipeClientStream.
# Both were wrong: MSYS collapses the leading '\\' to '\' (so the fork saw a
# file name, not a pipe), and the tap itself is a pipe *client*, so a client
# consumer can never be reached. The probe is now the pipe server and starts the
# client from PowerShell; this arm only judges its numbers.
taskkill //F //IM scrcpy.exe >/dev/null 2>&1
rm -rf "$out/pcm"
# PowerShell does not understand the /c/... paths this script works with, so the
# two paths handed to it are converted; the result is read from a file because
# the child process writes to the same console the pipeline is using
powershell -NoProfile -ExecutionPolicy Bypass -File "$root/tools/pcm_pipe_probe.ps1" \
    -Exe "$(cygpath -w "$exe")" -Serial "$serial" -Seconds "$secs" \
    -OutDir "$(cygpath -w "$out/pcm")" > "$out/pcm_probe.txt" 2>&1
cat "$out/pcm/client.out" "$out/pcm/client.err" > "$out/pcm.log" 2>/dev/null
pcmline=$(tr -d '\r' < "$out/pcm/result.txt" 2>/dev/null | tail -1)
pcm=$(sed -n 's/.*BYTES=\([0-9-]*\).*/\1/p' <<< "$pcmline")
first=$(sed -n 's/.*FIRST_MS=\([0-9-]*\).*/\1/p' <<< "$pcmline")
# a raw s16le file has no header to probe, so its length is the byte count over
# the nominal rate the client itself logged (48000 Hz x 2 ch x 16 bit)
dur=$(awk -v b="${pcm:-0}" 'BEGIN{ printf "%.2f", b/192000 }')
vol=$(ffmpeg -hide_banner -f s16le -ar 48000 -ac 2 -i "$out/pcm/pcm.raw" \
        -af volumedetect -f null NUL 2>&1 | grep -o 'max_volume: [-0-9.]* dB')
printf 'TAP  %s piped=%ss\n' "${pcmline:-no result}" "${dur:-0}"
# these two lines are the evidence that the name survived the shell: a mangled
# path is still logged, just without the second backslash
if grep -qF 'raw bytes -> \\.\pipe\gsc_pcm_probe' "$out/pcm.log" 2>/dev/null; then
    printf '  PASS the pipe name reached the client intact\n'
else
    printf '  FAIL the pipe name arrived mangled: %s\n' \
        "$(grep -o 'raw bytes -> .*' "$out/pcm.log" | head -1)"
    fails=$((fails+1))
fi
if grep -qF 'pcm tap: consumer connected' "$out/pcm.log" 2>/dev/null; then
    printf '  PASS the tap connected to the pipe server\n'
else
    printf '  FAIL the tap never reached a pipe server\n'
    fails=$((fails+1))
fi
case "${pcm:-}" in
    ''|0|none)
        printf '  FAIL the PCM tap delivered no bytes\n'
        fails=$((fails+1));;
    *)
        if [ $((pcm % 4)) -ne 0 ]; then
            printf '  FAIL %s B is not a whole number of s16le stereo frames\n' "$pcm"
            fails=$((fails+1))
        fi
        if awk -v d="${dur:-0}" 'BEGIN{ exit !(d < 1) }'; then
            printf '  FAIL only %s s of audio crossed the pipe\n' "${dur:-0}"
            fails=$((fails+1))
        fi
        if [ -z "${vol:-}" ]; then
            printf '  FAIL the bytes are not decodable as 48 kHz stereo s16le\n'
            fails=$((fails+1))
        else
            printf '  PASS %s B crossed the pipe, first byte after %s ms, %s s decodable as 48 kHz stereo (%s)\n' \
                "$pcm" "${first:-?}" "$dur" "$vol"
        fi
        printf '  NOTE %s\n' "$(grep -o 'pcm tap: [0-9]* chunks sent.*' "$out/pcm.log" | tail -1)"
        ;;
esac

# ---------- 60 s 1080p120 recording ------------------------------------------
rec=$out/rec1080p120.mp4
rm -f "$rec"
kill_scrcpy
"$exe" --serial="$serial" --video-codec=h264 --max-size=1080 --max-fps=120 \
    --video-bit-rate=30M --record="$rec" > "$out/rec1080p120.log" 2>&1 &
sleep 62
stop_scrcpy
wait 2>/dev/null
if [ -s "$rec" ]; then
    dur=$(ffprobe -hide_banner -v error -show_entries format=duration \
          -of csv=p=0 "$rec")
    dec_errs=$(ffmpeg -hide_banner -v error -i "$rec" -f null - 2>&1 | wc -l)
    printf 'REC  1080p120 size=%sB duration=%ss decode_error_lines=%s\n' \
        "$(wc -c < "$rec" | tr -d ' ')" "${dur:-n/a}" "$dec_errs"
    awk -v d="${dur:-0}" 'BEGIN{ exit !(d < 40) }' && {
        printf '  FAIL the 60 s recording is only %s s\n' "${dur:-0}"; fails=$((fails+1)); }
    [ "$dec_errs" -eq 0 ] || { printf '  FAIL the recording does not decode cleanly\n' \
                               ; fails=$((fails+1)); }
else
    printf 'REC  FAIL no 1080p120 file\n'; fails=$((fails+1))
fi

printf '\nRESULT fails=%s\n' "$fails"
[ "$fails" -eq 0 ] || exit 1
