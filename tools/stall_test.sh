#!/usr/bin/env bash
# Gate §22 "graceful failure" (v4 §1.3).
#
# The reported bug is a mirror window that shows no picture and then goes "Not
# Responding" until Windows kills it. Measured on the S23 Ultra, the trigger is
# the filter panel's second SDL window existing before the mirror has painted:
# the session never presents a first frame (0 telemetry lines) and
# IsHungAppWindow turns true. The fork now (a) builds that window only when the
# panel is first opened, after the mirror painted, and (b) arms a watchdog so a
# session that never paints says so and ends instead of hanging.
#
# Four arms, two per property:
#   painted    the panel must not cost the mirror its first frame
#   armed      the watchdog must fire and end the process cleanly
#   not armed  a healthy session must not be killed by it
#   no video   a --no-playback recording never paints, so it must never be armed
#
# The paint arms test "did a first frame arrive", which is what the bug was. They
# must not read that as "how many seconds produced a line": the telemetry line is
# emitted when a 1 s window rolls and a window only rolls when a packet arrives
# (gaming.c:2114), so a phone showing a static screen legitimately produces one or
# two lines in eight seconds. That threshold (>= 3) made this section measure the
# activity of the device rather than the behaviour of the panel, and it failed on
# a Motorola whose screen went quiet while the mirror kept the picture. The line
# count is still printed, with the best fps the session reported, so a quiet
# device is visible in the log instead of being silently accepted.
#
# The second paint arm asks for --game-overlay-visible, which the shipped client
# refuses at startup (overlay.c:1249) because that was the exact cause of the grey
# window. So the arm proves two things: the refusal is still there, and the mirror
# still paints. Opening the panel once the picture is up is measured without a
# device by tools/overlay_test.sh (gate 18).
#
# Liveness is read from the Windows process table by image name: bash's $! is an
# MSYS2 pid, which tasklist does not know, and the arms run one at a time so the
# count of scrcpy.exe rows is unambiguous. Without a device the session fails for
# a different reason, so the check reports SKIP and gives the commands instead of
# pretending to pass.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$root/dist/GamingScrcpy/scrcpy/scrcpy.exe
adb=$root/dist/GamingScrcpy/scrcpy/adb.exe
out=${OUT:-$root/out/stall}
serial=${SERIAL:-}
mkdir -p "$out"

export PATH="/c/msys64/ucrt64/bin:$root/dist/GamingScrcpy/scrcpy:$PATH"

if [ ! -f "$exe" ]; then
    echo "SKIP  no scrcpy.exe at $exe"
    exit 2
fi
if [ -z "$serial" ] && [ -f "$adb" ]; then
    serial=$("$adb" devices 2>/dev/null | sed -n 's/^\([[:graph:]]*\)[[:space:]]*device$/\1/p' | head -1)
fi
if [ -z "$serial" ]; then
    echo "SKIP  no device attached; by hand run:"
    echo "        $exe --game-filter-overlay --game-telemetry-log"
    echo "      and confirm telemetry lines appear (the picture is on screen)."
    exit 2
fi

count() { tasklist //FI "IMAGENAME eq scrcpy.exe" //NH 2>/dev/null | grep -ci 'scrcpy\.exe' || true; }

left=$(count)
if [ "$left" -ne 0 ]; then
    echo "FAIL  $left scrcpy.exe process(es) already running; the liveness count"
    echo "      would be ambiguous. Close them (or the launcher session) and rerun."
    exit 1
fi

fails=0

arm() { # name  extra-flags  seconds  expect(paint|alive|gone)
    local name=$1 extra=$2 secs=$3 expect=$4
    local log=$out/$name.txt alive=alive i=0 rc=0

    # shellcheck disable=SC2086
    "$exe" --serial="$serial" --video-codec=h264 --game-telemetry-log $extra \
        > "$log" 2>&1 &
    local pid=$!
    while [ $i -lt $((secs * 2)) ]; do
        sleep 0.5
        i=$((i + 1))
        if [ "$(count)" = 0 ]; then
            alive=gone
            break
        fi
    done
    if [ "$alive" = alive ]; then
        taskkill //F //IM scrcpy.exe >/dev/null 2>&1
    fi
    wait "$pid" 2>/dev/null
    rc=$?

    local tel stalled maxfps refused
    tel=$(grep -c 'telemetry:' "$log" 2>/dev/null)
    stalled=$(grep -c 'video-stalled' "$log" 2>/dev/null)
    maxfps=$(grep -o 'fps=[0-9.]*' "$log" 2>/dev/null | sed 's/fps=//' | sort -rn | head -1)
    refused=$(grep -c 'is disabled, it costs the mirror' "$log" 2>/dev/null)
    echo "note  $name [$extra] alive=$alive after=$((i / 2))s exit=$rc " \
         "telemetry=$tel best_fps=${maxfps:-0} stall_lines=$stalled"

    case $expect in
    paint)
        # the regression test for the grey window: the mirror got its first frame
        # and the watchdog had nothing to say about it
        if [ "$tel" -eq 0 ]; then
            echo "FAIL  $name: the mirror never painted, see $log"
            fails=$((fails + 1))
        elif [ "$stalled" -ne 0 ]; then
            echo "FAIL  $name: a painting session was reported as stalled"
            fails=$((fails + 1))
        else
            [ "$tel" -lt 3 ] && echo "note  $name: only $tel one-second window(s) carried a " \
                "new frame; that is the device screen being still, not a lost picture"
            echo "OK    $name: the filter panel did not cost the mirror its first frame"
        fi ;;
    paint+refused)
        # as above, plus the guard that makes the request safe: the client must
        # still refuse to build the panel window before the first paint
        if [ "$refused" -eq 0 ]; then
            echo "FAIL  $name: --game-overlay-visible is no longer refused at startup,"
            echo "      so this arm no longer proves the panel cannot steal the first frame"
            fails=$((fails + 1))
        fi
        if [ "$tel" -eq 0 ]; then
            echo "FAIL  $name: the mirror never painted, see $log"
            fails=$((fails + 1))
        elif [ "$stalled" -ne 0 ]; then
            echo "FAIL  $name: a painting session was reported as stalled"
            fails=$((fails + 1))
        elif [ "$refused" -gt 0 ]; then
            [ "$tel" -lt 3 ] && echo "note  $name: only $tel one-second window(s) carried a new frame"
            echo "OK    $name: the startup panel request is refused and the mirror paints"
        fi ;;
    gone)
        # a shorter timeout than the device needs: the watchdog must speak and
        # the process must end on its own, which is what a hung window cannot do
        if [ "$alive" != gone ]; then
            echo "FAIL  $name: the session outlived its stall timeout, the watchdog is inert"
            fails=$((fails + 1))
        elif [ "$stalled" -eq 0 ]; then
            echo "FAIL  $name: it ended (code $rc) but never said why, see $log"
            fails=$((fails + 1))
        else
            echo "OK    $name: a mirror that never paints ends by itself"
        fi ;;
    alive)
        if [ "$stalled" -ne 0 ]; then
            echo "FAIL  $name: the watchdog fired on a session that must not be watched"
            fails=$((fails + 1))
        elif [ "$alive" != alive ]; then
            echo "FAIL  $name: the session died on its own, see $log"
            fails=$((fails + 1))
        else
            echo "OK    $name: behaved as expected ($expect)"
        fi ;;
    esac
    rm -f "$out/rec_$name.mp4"
}

# CONTROL=1: prove the first-frame assertion can still fail. --no-playback never
# presents a frame by design, so a paint arm run against it must report FAIL; if it
# passes, the assertion has become vacuous (a threshold lowered too far looks exactly
# like this) and the section must not be trusted.
if [ "${CONTROL:-0}" = 1 ]; then
    arm control "--no-playback --record=$out/rec_control.mp4" 4 paint
    if [ $fails -eq 0 ]; then
        echo "FAIL  control: the paint arm passed on a session that cannot paint"
        exit 1
    fi
    echo "OK    control: the paint arm fails when nothing is presented"
    exit 0
fi

arm panel-hidden "--game-filter-overlay --game-stall-timeout=off" 8 paint
arm panel-startup "--game-filter-overlay --game-overlay-visible \
--game-stall-timeout=off" 8 'paint+refused'
arm watchdog "--game-stall-timeout=100" 8 gone
arm default "--game-stall-timeout=5000" 6 alive
arm no-video "--no-playback --record=$out/rec_novideo.mp4" 6 alive

if [ $fails -ne 0 ]; then
    echo "FAIL  graceful failure: $fails arm(s) wrong"
    exit 1
fi
echo "OK    graceful failure: the panel keeps the picture and a dead mirror ends by itself"
exit 0
