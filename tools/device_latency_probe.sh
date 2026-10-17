#!/usr/bin/env bash
# Measure the host side of the mirror on a real device.
#
# This needs a device (the only check in the suite that does). Without one it
# prints SKIP and exits 0, so the gate stays green on a machine with no phone.
#
# What it measures is the time between "the packet reached the PC" and "the
# picture was presented", which scrcpy computes per frame and --game-telemetry-log
# prints once per second plus a percentile summary at exit. It is NOT the whole
# glass-to-glass figure: the device's own capture+encode time is not observable
# from here.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
client="$root/dist/GamingScrcpy/scrcpy/scrcpy.exe"
adbwin='C:\Users\Administrator\Desktop\GamingCapture\dist\GamingScrcpy\scrcpy\adb.exe'
# every device command lands in out/dev/adb_audit.log for the owner to review
audit() { bash "$here/adb_audit.sh" "$*"; }
audit "adb devices"
serial=$(cd "$root/dist/GamingScrcpy/scrcpy" && ./adb.exe devices 2>/dev/null \
        | awk 'NR>1 && $2=="device" {print $1; exit}')

if [ ! -f "$client" ]; then
    echo "SKIP latency (no packaged client)"
    exit 0
fi
if [ -z "$serial" ]; then
    echo "SKIP latency (no adb device attached)"
    exit 0
fi

tmp=$(mktemp -d)
fail=0

run_case() {
    local name=$1; shift
    local log=$tmp/$name.log
    audit "scrcpy --serial=$serial --game-telemetry-log --video-bit-rate=48M --max-fps=60 --time-limit=18 $*"
    # 2 s to connect, then the wake shortcut, then 12 s of measurement, so the
    # scene is actually lit and the encoder has something to do.
    ADB="$adbwin" "$client" --serial="$serial" --game-telemetry-log \
        --video-bit-rate=48M --max-fps=60 --time-limit=18 \
        "$@" > "$log.raw" 2>&1 &
    local pid=$!
    sleep 6
    powershell.exe -NoProfile -ExecutionPolicy Bypass \
        -File "$here/wake_device_screen.ps1" > "$log.wake" 2>&1
    wait "$pid"
    sed 's/\x1b\[[0-9;]*m//g' "$log.raw" > "$log"
}

# median of the numbers on stdin
med() { sort -n | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]; else print "na"}'; }

for codec in h264 h265; do
    for mode in baseline lowlat; do
        extra=""
        [ "$mode" = lowlat ] && extra="--game-low-latency"
        run_case "${codec}-${mode}" --video-codec="$codec" $extra
        log=$tmp/${codec}-${mode}.log
        sum=$(grep -o 'telemetry-summary:.*' "$log" | tail -1)
        fps=$(grep -o 'fps=[0-9.]*' "$log" | cut -d= -f2 | med)
        kb=$(grep -o 'v_kbps=[0-9]*' "$log" | cut -d= -f2 | med)
        src=$(grep -o 'src=[0-9]*x[0-9]*' "$log" | tail -1 | cut -d= -f2)
        wake=$(grep -o 'RESULT wake.*' "$log.wake" | tail -1)
        # A black or asleep screen makes the encoder emit ~30 B frames, so the
        # latency below then describes a near-empty stream, not a game. Say so.
        scene=live
        [ "${kb:-0}" -lt 100 ] && scene=static
        echo "RESULT ${codec}/${mode} src=$src scene=$scene fps_med=$fps v_kbps_med=$kb"
        echo "       ${sum:-no-summary} | $wake"
        # a mirror that presents nothing has no latency at all
        if ! grep -q 'telemetry-summary' "$log"; then
            echo "FAIL ${codec}/${mode}: no telemetry summary"
            fail=1
        fi
        # the device must keep rendering at its own native size: the whole
        # project forbids changing it
        case "$src" in
            1920x1200|2000x1200|2560x1600|2560x1440|1600x2560|1200x1920|1080x2400|1440x3200) ;;
            "") echo "FAIL ${codec}/${mode}: no source size in the log"; fail=1 ;;
            *) echo "NOTE ${codec}/${mode}: native size is $src (recorded, not asserted)";;
        esac
    done
done

echo "RESULT serial=$serial"
[ $fail -eq 0 ] && echo "OK" || echo "FAILED"
exit $fail
