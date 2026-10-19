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
skips=0
# This is somebody's phone and it is allowed to be asleep when the harness is
# started. An asleep panel produces a near-empty encoder stream (a few frames a
# minute), no audio capture at all and a 799 KB "60 s" recording -- numbers that
# describe the scene, not the fork. The only wake this project is allowed to use
# is scrcpy's own MOD+O shortcut injected through its control channel, so that is
# what each session gets; and if the scene still refuses to light, the arms report
# a SKIP with the reason instead of a product FAIL.
wake_screen() {
    powershell -NoProfile -ExecutionPolicy Bypass \
        -File "$root/tools/wake_device_screen.ps1" 2>/dev/null \
        | grep -o 'RESULT wake.*' | tail -1
}
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
sleep 4
wake=$(wake_screen)
sleep 4
kill_scrcpy
wait 2>/dev/null
pre=$(grep -c 'telemetry:' "$out/preflight.txt")
if [ "$pre" -eq 0 ]; then
    printf 'ABORT  the preflight painted no frame, so every arm below would measure 0\n'
    sed -n '1,10p' "$out/preflight.txt"
    exit 1
fi
# one telemetry line per second of *presented* video: a phone whose panel is off
# or locked presents a few frames a minute, and no measurement taken in that state
# belongs in a baseline table.
prefps=$(grep -o 'fps=[0-9.]\+' "$out/preflight.txt" | sed 's/fps=//' \
    | sort -n | awk '{v[NR]=$1} END{ if (NR) printf "%.1f", v[int((NR+1)/2)]; else print 0 }')
scene_live=1
awk -v f="$prefps" 'BEGIN{ exit !(f < 20) }' && scene_live=0
printf 'preflight ok (%s telemetry lines in 8 s, fps_med=%s) %s scene=%s\n' \
    "$pre" "$prefps" "${wake:-no wake sent}" \
    "$( [ "$scene_live" = 1 ] && echo live || echo static )"
if [ "$scene_live" = 0 ]; then
    printf 'NOTE   the panel stayed dark or locked: latency medians below describe a sleeping encoder and the audio/recording arms report SKIP. Light the screen, unlock the phone and re-run for baseline numbers.\n\n'
fi

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
        sleep 4
        wake_screen > /dev/null
        sleep $((secs - 4))
        stop_scrcpy
        wait 2>/dev/null
        grep -o 'lat=[0-9]\+' "$log" | sed 's/lat=//' >> "$all"
        grep -o 'fps=[0-9.]\+' "$log" | sed 's/fps=//' >> "$fpsf"
    done
    fpsm=$(sort -n "$fpsf" | awk '{v[NR]=$1} END{ if (NR==0) print "n/a"; \
        else printf "%d", (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2 }')
    printf 'LAT %-22s %s fps_med=%s scene=%s\n' "$lbl" "$(stats "$all")" "$fpsm" \
        "$( awk -v f="$fpsm" 'BEGIN{ print (f+0 >= 20) ? "live" : "static" }' )"
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
    sleep 4
    wake_screen > /dev/null
    sleep $((secs - 4))
    stop_scrcpy
    wait 2>/dev/null
    if [ ! -s "$rec" ]; then
        if [ "$scene_live" = 0 ]; then
            printf 'AUDIO %-8s SKIP no recording while the panel was dark/locked\n' "$codec"
            skips=$((skips+1))
        else
            printf 'AUDIO %-8s FAIL no recording produced\n' "$codec"
            fails=$((fails+1))
        fi
        return
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
        # Android hands AudioPlaybackCapture nothing while the device is asleep
        # or on the keyguard, and a dark panel also starves the encoder, so a
        # missing stream in that state measures the scene (v4 §6.2, BUILD_REPORT
        # §5.1at). With a lit panel it is a FAIL again.
        if [ "$scene_live" = 0 ]; then
            printf '  SKIP %s: no audio stream while the device was dark/locked -- light it, unlock it, play something and re-run\n' "$codec"
            skips=$((skips+1))
        else
            printf '  FAIL %s: the recording has no audio stream\n' "$codec"
            fails=$((fails+1))
        fi
    elif awk -v v="$vol" 'BEGIN{ exit !(v < -60) }'; then
        printf '  SKIP %s: the captured stream is digital silence (%s dB); nothing was playing on the phone and the device rules forbid starting media, so audibility stays a manual check (BUILD_REPORT §5.1at)\n' "$codec" "$vol"
        skips=$((skips+1))
    else
        printf '  PASS %s: audio stream (%s) carries real content at %s dB\n' \
            "$codec" "$acodec" "$vol"
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
        # the tap can only forward what the device captured, and a dark/locked
        # phone captures nothing: same scene rule as the audio arms above
        if [ "$scene_live" = 0 ]; then
            printf '  SKIP no PCM bytes while the device was dark/locked (the pipe itself connected)\n'
            skips=$((skips+1))
        else
            printf '  FAIL the PCM tap delivered no bytes with a live scene\n'
            fails=$((fails+1))
        fi;;
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
sleep 4
wake_screen > /dev/null
sleep 58
stop_scrcpy
wait 2>/dev/null
if [ -s "$rec" ]; then
    dur=$(ffprobe -hide_banner -v error -show_entries format=duration \
          -of csv=p=0 "$rec")
    # The criterion is "both streams fully decode and the stored dts is
    # monotonic", not "ffmpeg -v error prints nothing". The old arm counted the
    # lines of a transcode-to-null pass, and that pass emits "non monotonically
    # increasing dts to muxer" for a healthy variable-frame-rate recording: the
    # null muxer re-times the frames it is handed. Upstream scrcpy 5.0.1 draws
    # the identical message from the same session (BUILD_REPORT §5.1b3), so the
    # count measured the harness. ffprobe -count_frames decodes every frame with
    # no muxer in the loop and still reports decoder errors.
    dec_errs() { # stream letter -> decoder error lines, and frame count on stdout
        ffprobe -hide_banner -v error -count_frames -select_streams "$1:0" \
            -show_entries stream=nb_read_frames -of csv=p=0 "$rec"
    }
    vout=$(dec_errs v); aout=$(dec_errs a)
    vframes=$(grep -o '^[0-9]*$' <<< "$vout" | tail -1)
    verr=$(grep -v '^[0-9]*$' <<< "$vout")
    aer=$(grep -v '^[0-9]*$' <<< "$aout")
    # stored packet order, read straight out of the container
    dts_bad() { # stream letter -> packets whose dts is below its predecessor's
        ffprobe -hide_banner -v error -select_streams "$1:0" -show_entries \
            packet=dts -of csv=p=0 "$rec" 2>/dev/null \
            | grep -E '^-?[0-9]+$' \
            | awk 'NR>1 && $1+0<prev {c++} {prev=$1+0} END{print c+0}'
    }
    vbad=$(dts_bad v); abad=$(dts_bad a)
    muxnote=$(ffmpeg -hide_banner -v error -i "$rec" -f null - 2>&1 \
              | grep -c 'non monotonically increasing dts' || true)
    printf 'REC  1080p120 size=%sB duration=%ss video_frames=%s decode_errors=%s+%s dts_out_of_order=%s+%s scene=%s\n' \
        "$(wc -c < "$rec" | tr -d ' ')" "${dur:-n/a}" "${vframes:-0}" \
        "$([ -n "$verr" ] && printf '%s' "$verr" | wc -l | tr -d ' ' || echo 0)" \
        "$([ -n "$aer" ] && printf '%s' "$aer" | wc -l | tr -d ' ' || echo 0)" \
        "$vbad" "$abad" \
        "$( [ "$scene_live" = 1 ] && echo live || echo static )"
    if [ "$scene_live" = 0 ]; then
        printf '  SKIP a dark panel encodes almost nothing: %sB for 60 s is the scene, not the recorder\n' \
            "$(wc -c < "$rec" | tr -d ' ')"
        skips=$((skips+1))
    else
        rfails=0
        awk -v d="${dur:-0}" 'BEGIN{ exit !(d < 40) }' && {
            printf '  FAIL the 60 s recording is only %s s\n' "${dur:-0}"; rfails=$((rfails+1)); }
        [ -n "$verr" ] && { printf '  FAIL the video stream does not decode: %s\n' \
            "$(head -1 <<< "$verr")"; rfails=$((rfails+1)); }
        [ -n "$aer" ] && { printf '  FAIL the audio stream does not decode: %s\n' \
            "$(head -1 <<< "$aer")"; rfails=$((rfails+1)); }
        [ "${vframes:-0}" -gt 0 ] || { printf '  FAIL no video frame could be decoded\n' \
            ; rfails=$((rfails+1)); }
        [ "$vbad" -eq 0 ] && [ "$abad" -eq 0 ] || {
            printf '  FAIL the container stores out-of-order dts (video %s, audio %s packets)\n' \
                "$vbad" "$abad"; rfails=$((rfails+1)); }
        # kept visible, deliberately not asserted: the null muxer's own re-timing
        printf '  NOTE the old criterion would have failed this file on %s "non monotonically increasing dts" lines from the null-muxer re-time pass (stock scrcpy prints the same on the same session)\n' "${muxnote:-0}"
        # and prove the new instrument is not simply blind: a truncated copy of
        # the same file must be rejected by it
        cutf=$out/rec_truncated.mp4
        head -c $(($(wc -c < "$rec") / 2)) "$rec" > "$cutf"
        if ffprobe -hide_banner -v error -count_frames -select_streams v:0 \
                -show_entries stream=nb_read_frames -of csv=p=0 "$cutf" 2>&1 \
           | grep -q '[a-z]'; then
            printf '  PASS positive control: the same check rejects a truncated recording\n'
        else
            printf '  FAIL the decode check is blind: it accepted a truncated recording\n'
            rfails=$((rfails+1))
        fi
        rm -f "$cutf"
        if [ "$rfails" -eq 0 ]; then
            printf '  PASS every frame of both streams decodes and both stored dts sequences are monotonic (%s video frames in %s s)\n' \
                "$vframes" "${dur:-?}"
        else
            fails=$((fails+rfails))
        fi
    fi
else
    printf 'REC  FAIL no 1080p120 file\n'; fails=$((fails+1))
fi

printf '\nRESULT fails=%s skips=%s\n' "$fails" "$skips"
[ "$fails" -eq 0 ] || exit 1
