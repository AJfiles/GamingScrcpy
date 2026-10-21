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

# Arms whose screen was actually moving. Only those can carry a latency claim, so
# the script reports SKIP instead of a product failure when none of them exists.
live=0
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
        # A still screen makes the encoder emit almost nothing, so the percentiles
        # then describe the age of one old frame rather than a game. Classify the
        # arm by the bytes, and only by a number: med() prints "na" when no window
        # arrived, and [ "na" -lt 100 ] is a bash error that used to leave such an
        # arm labelled live while it had measured nothing at all.
        case "$kb" in
            ''|*[!0-9]*)
                scene=none ;;
            *)
                if [ "$kb" -lt 100 ]; then scene=static; else scene=live; fi ;;
        esac
        has_sum=0
        if grep -q 'telemetry-summary' "$log"; then
            has_sum=1
        fi
        # How much was actually measured, which is not the same question as whether
        # the screen moved: the summary is one number per second-window, and a
        # percentile over a single window is not a measurement (this run produced
        # seconds=1 lat_med=401ms next to seconds=17 lat_med=212ms on the same
        # phone). Count an arm as carrying a number only from five windows up.
        secs=$(printf '%s' "$sum" | sed -n 's/.*seconds=\([0-9]*\).*/\1/p')
        case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
        meas=0
        if [ "$has_sum" = 1 ] && [ "$secs" -ge 5 ]; then
            meas=1
            live=$((live + 1))
        else
            echo "NOTE ${codec}/${mode}: scene=$scene seconds=$secs: too little measured here to carry a latency number"
        fi
        echo "RESULT ${codec}/${mode} src=$src scene=$scene seconds=$secs fps_med=$fps v_kbps_med=$kb"
        echo "       ${sum:-no-summary} | $wake"
        # the device must keep rendering at its own native size: the whole
        # project forbids changing it
        case "$src" in
            1920x1200|2000x1200|2560x1600|2560x1440|1600x2560|1200x1920|1080x2400|1440x3200) ;;
            "") if [ "$meas" = 1 ]; then
                    echo "FAIL ${codec}/${mode}: $secs measured seconds but no source size in the log"
                    fail=1
                fi ;;
            *) echo "NOTE ${codec}/${mode}: native size is $src (recorded, not asserted)";;
        esac
    done
done

echo "RESULT serial=$serial"
if [ "$live" -eq 0 ]; then
    # Nothing here is a product failure: with no moving picture the mirror has no
    # frames to time, and lat_med would then be the age of one old frame (the run
    # that produced this line reported 12369 ms on a still phone). Say what is
    # missing and how to get it instead of failing the build for the phone's state.
    echo "SKIP no arm measured at least five one-second windows on $serial: the phone showed a still screen, so latency cannot be measured here. Play a video on the phone (owner action, README section 7) and rerun."
    exit 2
fi
[ $fail -eq 0 ] && echo "OK" || echo "FAILED"
exit $fail
