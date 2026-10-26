#!/usr/bin/env bash
# Recording integrity without a device.
#
# sc_recorder only muxes packets it is given, so the device is not needed to
# test it: encode a real clip with ffmpeg, feed the elementary stream to
# recorderintegrity (which drives sc_recorder exactly like the demuxer thread
# does), then probe and fully decode the recorded file.
#
#   bash tools/recorder_integrity_test.sh [frames] [WxH]
#
# Exits 77 when ffmpeg is unavailable, so the gate stays usable without it.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/c/msys64/ucrt64/bin:$PATH"

FRAMES="${1:-30}"
SIZE="${2:-320x240}"
FPS=30
# the dual-recording case uses a bigger, realistically sized stream
BW=1280
BH=720
BFRAMES=120
BSIZE="${BW}x${BH}"

. "$ROOT/tools/layout.sh"
BIN="$SRC/build-x/app/recorderintegrity.exe"
[ -x "$BIN" ] || BIN="$SRC/build-usb/app/recorderintegrity.exe"
# this same script also ships inside the package, where the harness sits next
# to scrcpy.exe instead of in a build tree
[ -x "$BIN" ] || BIN="$ROOT/scrcpy/recorderintegrity.exe"
if [ ! -x "$BIN" ]; then
    echo "SKIP recorderintegrity.exe not built"
    exit 77
fi
command -v ffmpeg >/dev/null || { echo "SKIP ffmpeg not installed"; exit 77; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

W="${SIZE%x*}"
H="${SIZE#*x}"
# the device sends 48 kHz stereo s16le when --audio-codec=raw, in 10 ms frames
ACHUNKS=$(( FRAMES * 100 / FPS ))
ABYTES=$(( ACHUNKS * 480 * 2 * 2 ))
CUT=$(( FRAMES / 3 ))
fail=0

vframes() { # file
    ffprobe -v error -select_streams v:0 -count_frames \
            -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$1"
}
apackets() { # file
    ffprobe -v error -select_streams a:0 -count_packets \
            -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$1"
}
vfield() { # file, field
    ffprobe -v error -select_streams v:0 -show_entries "stream=$2" \
            -of default=nw=1:nk=1 "$1"
}
afield() { # file, field
    ffprobe -v error -select_streams a:0 -show_entries "stream=$2" \
            -of default=nw=1:nk=1 "$1"
}
dec_err() { # file -> nothing at all when the container decodes cleanly
    ffmpeg -v error -i "$1" -f null NUL 2>&1
}

# Encode $FRAMES frames of a synthetic test picture into an Annex-B elementary
# stream. No B-frames: the harness feeds pts == dts, exactly like the device
# encoder does for the low-latency profiles scrcpy uses.
encode() { # file, codec, stream format, extra args
    ffmpeg -hide_banner -loglevel error -y \
           -f lavfi -i "testsrc2=size=${W}x${H}:rate=${FPS}" \
           -frames:v "$FRAMES" -c:v "$2" -preset ultrafast -bf 0 $4 -an \
           -f "$3" "$1"
}

check_case() { # label, input args, codec ffprobe reports, format, out ext
    local label="$1" input="$2" want="$3" fmt="$4" ext="$5"
    local out="$T/$label-out.$ext"

    # shellcheck disable=SC2086  # the input string is built above, not by a user
    if ! "$BIN" $input "--out=$out" "--format=$fmt" > "$T/$label.log" 2>&1; then
        echo "FAIL $label: the harness reported a failure"
        sed -n '1,12p' "$T/$label.log" | sed 's/^/        /'
        fail=1
        return
    fi

    local c w h n dec
    c="$(vfield "$out" codec_name)"
    w="$(vfield "$out" width)"
    h="$(vfield "$out" height)"
    n="$(vframes "$out")"
    # a clean decode prints nothing at all
    dec="$(dec_err "$out")"

    echo "RESULT $label file=out.$ext codec=$c size=${w}x${h} frames=$n/$FRAMES"

    local bad=0
    [ "$c" = "$want" ] || { echo "  expected codec $want, got $c"; bad=1; }
    [ "$w" = "$W" ] && [ "$h" = "$H" ] \
        || { echo "  expected $SIZE, got ${w}x${h}"; bad=1; }
    [ "$n" = "$FRAMES" ] || { echo "  decoded $n of $FRAMES frames"; bad=1; }
    [ -z "$dec" ] || { echo "  decode errors: $dec"; bad=1; }
    [ "$bad" -eq 0 ] || fail=1
}

# Two timelines in one container: video and raw PCM interleaved by pts, which
# is what a real --record=... with --audio-source=output looks like.
check_av_case() { # label, input args, format, ext
    local label="$1" input="$2" fmt="$3" ext="$4"
    local out="$T/$label-out.$ext"

    # shellcheck disable=SC2086
    if ! "$BIN" $input "--audio-in=$T/src.pcm" "--out=$out" "--format=$fmt" \
            > "$T/$label.log" 2>&1; then
        echo "FAIL $label: the harness reported a failure"
        sed -n '1,12p' "$T/$label.log" | sed 's/^/        /'
        fail=1
        return
    fi

    local nst n acodec adec2 sr ch vol apk
    nst="$(ffprobe -v error -show_entries format=nb_streams \
                  -of default=nw=1:nk=1 "$out")"
    n="$(vframes "$out")"
    acodec="$(afield "$out" codec_name)"
    sr="$(afield "$out" sample_rate)"
    ch="$(afield "$out" channels)"
    apk="$(apackets "$out")"
    adec2="$(dec_err "$out")"
    # volumedetect logs at info level, so no -v error for this one
    vol="$(ffmpeg -hide_banner -i "$out" -map 0:a -af volumedetect -f null NUL \
                  2>&1 | sed -n 's/.*max_volume: \(-[0-9.]*\) dB/\1/p')"

    echo "RESULT $label streams=$nst video_frames=$n/$FRAMES audio_packets=$apk/$ACHUNKS audio=$acodec/${sr}Hz/${ch}ch max_volume=${vol}dB"

    local bad=0
    [ "$nst" = 2 ] || { echo "  expected 2 streams, got $nst"; bad=1; }
    [ "$n" = "$FRAMES" ] || { echo "  decoded $n of $FRAMES video frames"; bad=1; }
    [ "$apk" = "$ACHUNKS" ] \
        || { echo "  muxed $apk of $ACHUNKS audio packets"; bad=1; }
    [ "$acodec" = pcm_s16le ] || { echo "  audio codec is $acodec"; bad=1; }
    [ "$sr" = 48000 ] || { echo "  audio rate is $sr"; bad=1; }
    [ "$ch" = 2 ] || { echo "  audio channels is $ch"; bad=1; }
    [ -z "$adec2" ] || { echo "  decode errors: $adec2"; bad=1; }
    # the tone must really be in there: silence reports -91 dB
    awk -v v="${vol:--91}" 'BEGIN { exit !(v > -40) }' \
        || { echo "  the audio stream is silent (${vol}dB)"; bad=1; }
    [ "$bad" -eq 0 ] || fail=1
}

# Stop in the middle, with no end of stream: the recorder must still drain its
# queues and write a playable trailer. For mp4 that means the moov atom, which
# a killed process would leave missing.
check_cut_case() { # label, input args, format, ext
    local label="$1" input="$2" fmt="$3" ext="$4"
    local out="$T/$label-out.$ext"

    # shellcheck disable=SC2086
    if ! "$BIN" $input "--audio-in=$T/src.pcm" "--out=$out" "--format=$fmt" \
              "--stop-after=$CUT" > "$T/$label.log" 2>&1; then
        echo "FAIL $label: the harness reported a failure"
        sed -n '1,12p' "$T/$label.log" | sed 's/^/        /'
        fail=1
        return
    fi

    local n apk dur dec alo ahi
    n="$(vframes "$out")"
    apk="$(apackets "$out")"
    dur="$(ffprobe -v error -show_entries format=duration \
                  -of default=nw=1:nk=1 "$out")"
    dec="$(dec_err "$out")"
    # packets that had already reached the recorder when the stop arrived
    alo=$(( ( CUT - 1 ) * 100 / FPS ))
    ahi=$(( CUT * 100 / FPS ))

    echo "RESULT $label cut=$CUT video_frames=$n audio_packets=$apk/${ACHUNKS} duration=${dur}s"

    local bad=0
    [ "$n" = "$CUT" ] || { echo "  kept $n frames, expected $CUT"; bad=1; }
    [ "$apk" -ge "$alo" ] && [ "$apk" -le "$ahi" ] \
        || { echo "  audio stopped at packet $apk, expected ${alo}..${ahi}"; bad=1; }
    [ "$apk" -lt "$ACHUNKS" ] \
        || { echo "  all audio was written: the stop behaved like EOS"; bad=1; }
    awk -v d="${dur:-0}" -v cut="$CUT" -v fps="$FPS" \
        'BEGIN { exit !(d >= cut / fps - 0.05) }' \
        || { echo "  duration ${dur}s is shorter than ${CUT} frames of video"; bad=1; }
    [ -z "$dec" ] || { echo "  decode errors: $dec"; bad=1; }
    [ "$bad" -eq 0 ] || fail=1
}

es_args() { # elementary stream file, codec name
    printf -- '--in=%s --codec=%s --size=%s --fps=%s' "$1" "$2" "$SIZE" "$FPS"
}

# What attaching --record costs the thread that also feeds the mirror: the same
# packets are pushed at the stream rate once into a sink that does nothing and
# once into a live recorder writing to disk.
check_bench_case() { # label, src, es name, fps
    local label="$1" src="$2" es="$3" fps="$4"
    local budget=$(( 1000000 / fps ))   # one frame interval, microseconds
    local attempt line added max queued drain frames bad

    # Two attempts, because these bounds measure how the OS scheduled a thread.
    # Typical values are 13-63 us added per push and a sub-millisecond worst
    # frame, but a first write can be preempted for hundreds of milliseconds by
    # the disk or by an antivirus scanning the new file (observed: push_max 339 ms
    # with the same average otherwise in band). Retrying once keeps the bounds
    # strict -- a genuine regression stalls every attempt -- without turning a
    # scheduling accident into a fake failure.
    for attempt in 1 2; do
        local out="$T/$label-out$attempt.mkv" log="$T/$label.$attempt.log"
        if ! "$BIN" "--in=$src" "--out=$out" --format=mkv "--codec=$es" \
                  "--size=$BSIZE" "--fps=$fps" --bench > "$log" 2>&1; then
            echo "FAIL $label: the harness reported a failure"
            sed -n '1,12p' "$log" | sed 's/^/        /'
            fail=1
            return
        fi

        line="$(grep '^recorderlatency:' "$log")"
        added="$(sed -n 's/.*added=\([0-9]*\)ns.*/\1/p' <<<"$line")"
        max="$(sed -n 's/.*push_max=\([0-9]*\)us.*/\1/p' <<<"$line")"
        queued="$(sed -n 's/.*still_queued=\([0-9]*\)[^0-9].*/\1/p' <<<"$line")"
        drain="$(sed -n 's/.*drain=\([0-9]*\)ms.*/\1/p' <<<"$line")"
        frames="$(sed -n 's/^recorderlatency: frames=\([0-9]*\).*/\1/p' <<<"$line")"

        echo "RESULT $label attempt=$attempt frames=$frames interval=${budget}us added=${added}ns push_max=${max}us still_queued=${queued} drain=${drain}ms"

        bad=0
        [ -n "$added" ] && [ -n "$max" ] && [ -n "$queued" ] && [ -n "$drain" ] \
            || { echo "        no numbers parsed from: $line"; bad=1; }
        # Queue depth is a property of the machine, not of the recorder: measured
        # on this host it ranges from 0 to 118 of 120 packets depending on what
        # else is running, because the writer thread is deliberately low priority.
        # What is asserted instead is that the backlog never exceeds the stream
        # and that the writer catches up within 3 s of the last frame.
        [ "${queued:-999}" -le "${frames:-0}" ] \
            || { echo "        more packets queued than pushed: $queued of $frames"; bad=1; }
        awk -v d="${drain:-99999}" 'BEGIN { exit !(d < 3000) }' \
            || { echo "        the writer had not caught up 3 s after the last frame (drain=${drain}ms)"; bad=1; }
        # the extra cost of recording must stay under a tenth of the frame interval
        awk -v a="${added:-0}" -v lim=$(( budget * 100 )) \
            'BEGIN { exit !(a < lim) }' \
            || { echo "        recording added ${added}ns per frame, limit $(( budget / 10 ))us"; bad=1; }
        # and no single frame may be held up for a whole frame interval
        awk -v m="${max:-0}" -v lim="$budget" 'BEGIN { exit !(m < lim) }' \
            || { echo "        the slowest push cost ${max}us, over the ${budget}us interval"; bad=1; }

        if [ "$bad" -eq 0 ]; then
            [ "$attempt" -gt 1 ] && \
                echo "        (clean on retry: the first attempt was preempted)"
            return
        fi
        [ "$attempt" -eq 1 ] && sleep 5
    done

    echo "        $label stalled on both attempts"
    fail=1
}

# H.264 into both containers the launcher offers
if encode "$T/src.h264" libx264 h264 "-profile:v baseline"; then
    check_case h264-mkv "$(es_args "$T/src.h264" h264)" h264 mkv mkv
    check_case h264-mp4 "$(es_args "$T/src.h264" h264)" h264 mp4 mp4

    if ffmpeg -hide_banner -loglevel error -y \
              -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$(( ACHUNKS / 100 ))" \
              -ac 2 -ar 48000 -c:a pcm_s16le -f s16le "$T/src.pcm"; then
        if [ "$(stat -c%s "$T/src.pcm")" = "$ABYTES" ]; then
            check_av_case av-mkv "$(es_args "$T/src.h264" h264)" mkv mkv
            check_cut_case cut-mkv "$(es_args "$T/src.h264" h264)" mkv mkv
            check_cut_case cut-mp4 "$(es_args "$T/src.h264" h264)" mp4 mp4
        else
            echo "FAIL the PCM fixture is $(stat -c%s "$T/src.pcm") B, expected $ABYTES"
            fail=1
        fi
    else
        echo "FAIL could not encode the PCM test stream"
        fail=1
    fi
else
    echo "FAIL could not encode the H.264 test stream"
    fail=1
fi

# HEVC when an encoder is available for it (same Annex-B path, different
# codec id and config NALs)
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libx265' \
        && encode "$T/src.h265" libx265 hevc ""; then
    check_case hevc-mkv "$(es_args "$T/src.h265" hevc)" hevc mkv mkv
else
    echo "INFO no HEVC encoder available, skipping that case"
fi

# AV1 reaches the recorder as OBU temporal units with the config in the
# container, not as Annex-B, so it needs the other input mode
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1' \
        && ffmpeg -hide_banner -loglevel error -y \
             -f lavfi -i "testsrc2=size=${W}x${H}:rate=${FPS}" \
             -frames:v "$FRAMES" -c:v libsvtav1 -preset 12 -crf 40 -an \
             -f ivf "$T/src.av1" > /dev/null 2>&1; then
    check_case av1-mkv "--container-in=$T/src.av1 --size=$SIZE --fps=$FPS" av1 mkv mkv
    check_case av1-mp4 "--container-in=$T/src.av1 --size=$SIZE --fps=$FPS" av1 mp4 mp4
    if [ -f "$T/src.pcm" ]; then
        check_av_case av1-audio-mkv "--container-in=$T/src.av1 --size=$SIZE --fps=$FPS" mkv mkv
    fi
else
    echo "INFO no AV1 encoder available, skipping those cases"
fi

# Dual recording: a 720p clip with ~30 kB frames, pushed at 60 and at 120 fps
if ffmpeg -hide_banner -loglevel error -y \
          -f lavfi -i "testsrc2=size=${BW}x${BH}:rate=${FPS}" \
          -frames:v "$BFRAMES" -c:v libx264 -preset ultrafast -bf 0 -qp 24 \
          -profile:v high -an -f h264 "$T/bench.h264"; then
    check_bench_case dual-60fps "$T/bench.h264" h264 60
    check_bench_case dual-120fps "$T/bench.h264" h264 120
else
    echo "FAIL could not encode the dual-recording test stream"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "OK"
    exit 0
fi
exit 1
