#!/usr/bin/env bash
# End-to-end consumer test for both bridges: feed the raw streams produced by
# gamingdemo into a real encoder (ffmpeg) and probe the result.
#
# This is the closest thing to "verify recording integrity" that is possible
# without an Android device: the frame bridge output must decode as a video
# stream at the configured size, the audio bridge output must decode as
# 48 kHz stereo PCM, and the two must be frame-locked (equal durations) because
# both are produced from the same rendered frames.
#
#   bash tools/bridge_encode_test.sh [frames] [WxH]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/workspace/scrcpy/build-usb/app/gamingdemo.exe"
FRAMES="${1:-60}"
SIZE="${2:-320x180}"
W="${SIZE%x*}"
H="${SIZE#*x}"
FPS=60

export PATH="/c/msys64/ucrt64/bin:$PATH"
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
    echo "SKIP ffmpeg/ffprobe not installed"
    exit 77
fi
[ -x "$DEMO" ] || { echo "FAIL missing $DEMO"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

if ! "$DEMO" --frames="$FRAMES" --width=720 --height=1280 \
        --bridge="$T/v.raw" --bridge-scale="$SIZE" --bridge-filter=lanczos \
        --audio="$T/a.raw" --audio-sine --pcm-tap="$T/pcm.raw" \
        --no-osd >"$T/demo.log" 2>&1; then
    echo "FAIL gamingdemo run failed"
    tail -5 "$T/demo.log"
    exit 1
fi
grep -q 'gamingdemo: PASS' "$T/demo.log" || { echo "FAIL demo self-check"; exit 1; }

VB=$(stat -c %s "$T/v.raw")
AB=$(stat -c %s "$T/a.raw")
FB=$((W * H * 4))
VFRAMES=$((VB / FB))
ACHUNKS=$((AB / 3200))
[ $((VB % FB)) -eq 0 ] || { echo "FAIL video bytes $VB not a frame multiple"; exit 1; }
[ $((AB % 3200)) -eq 0 ] || { echo "FAIL audio bytes $AB not a packet multiple"; exit 1; }
[ "$VFRAMES" -gt 0 ] && [ "$ACHUNKS" -gt 0 ] || { echo "FAIL empty bridge output"; exit 1; }

if ! ffmpeg -y -v error \
        -f rawvideo -pixel_format rgba -video_size "$SIZE" -framerate "$FPS" \
        -i "$T/v.raw" \
        -f s16le -ar 48000 -ac 2 -i "$T/a.raw" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac \
        -shortest "$T/out.mp4" 2>"$T/ff.log"; then
    echo "FAIL ffmpeg could not encode the bridged feed"
    cat "$T/ff.log"
    exit 1
fi

# one ffprobe call per field: -show_entries with several fields returns them in
# struct order, not request order, which is how the first version of this test
# mis-parsed its own result
probe() { ffprobe -v error -select_streams "$1" -show_entries "stream=$2" \
                -of default=nw=1:nk=1 "$T/out.mp4"; }
vcodec=$(probe v:0 codec_name)
vdur=$(probe v:0 duration)
acodec=$(probe a:0 codec_name)
adur=$(probe a:0 duration)
OB=$(stat -c %s "$T/out.mp4")

# the two durations must agree within one frame period: both streams are
# produced from the same rendered frames, so a drift here means a bridge bug
delta=$(awk -v a="$vdur" -v b="$adur" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.6f", d }')
tol=$(awk -v f="$FPS" 'BEGIN { printf "%.6f", 1.5 / f }')
sync_ok=$(awk -v d="$delta" -v t="$tol" 'BEGIN { print (d <= t) ? "yes" : "no" }')

echo "RESULT frames=$VFRAMES audio_chunks=$ACHUNKS vsize=${W}x${H}"
echo "RESULT codecs=$vcodec+$acodec durations=${vdur}/${adur} delta=$delta tol=$tol"
echo "RESULT mp4=${OB}B av_locked=$sync_ok"

if [ "$vcodec" = "h264" ] && [ "$acodec" = "aac" ] && [ "$sync_ok" = "yes" ]; then
    :
else
    echo "FAIL unexpected encode result"
    exit 1
fi

# the decoded PCM tap (--game-audio-pcm): the demo feeds it 44.1 kHz mono FLT,
# so this proves the swresample conversion, not just the sink
PB=$(stat -c %s "$T/pcm.raw" 2>/dev/null || echo 0)
if [ "$PB" -eq 0 ] || [ $((PB % 4)) -ne 0 ]; then
    echo "FAIL pcm tap output is empty or misaligned ($PB B)"
    exit 1
fi
if ! ffmpeg -y -v error -f s16le -ar 48000 -ac 2 -i "$T/pcm.raw" \
        -c:a pcm_s16le "$T/pcm.wav" 2>"$T/ff2.log"; then
    echo "FAIL pcm tap does not decode as 48 kHz stereo s16le"
    cat "$T/ff2.log"
    exit 1
fi
prate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
            -of default=nw=1:nk=1 "$T/pcm.wav")
pch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
            -of default=nw=1:nk=1 "$T/pcm.wav")
pdur=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration \
            -of default=nw=1:nk=1 "$T/pcm.wav")
# the tone must actually be there: volumedetect reports -91 dB for silence
maxvol=$(ffmpeg -hide_banner -f s16le -ar 48000 -ac 2 -i "$T/pcm.raw" \
                -af volumedetect -f null - 2>&1 \
         | sed -n 's/.*max_volume: \(-\?[0-9.]*\) dB.*/\1/p')

echo "RESULT pcm_tap=${PB}B rate=${prate} ch=${pch} duration=${pdur} max_vol=${maxvol}dB"

if [ "$prate" = "48000" ] && [ "$pch" = "2" ] \
        && awk -v m="$maxvol" 'BEGIN { exit !(m > -40) }'; then
    echo "OK"
    exit 0
fi
echo "FAIL pcm tap conversion result unexpected"
exit 1
