#!/usr/bin/env bash
# Directive v4 §6.1: every shipped session profile has to mirror a real phone.
#
# `--validate-profiles` proves the command line *parses*; it cannot prove the
# device accepts it. An encoder that refuses a resolution, a codec a panel cannot
# produce, or a profile that paints grey all pass the parse test. This sweep runs
# each builtin profile as an actual session and judges what the fork reports:
#
#   * telemetry lines > 0     -- frames really reached the screen
#   * the window closed by itself within 10 s of a WM_CLOSE -- a session that has
#     gone "Not responding" cannot be closed, which is the bug this section is
#     about, so it is measured rather than trusted
#   * the client's own ERROR lines are printed for the record
#
# The command lines are not copied into this script. They are dumped by the
# launcher's --dump-profile-args, i.e. the same BuildArguments() a session uses,
# so the sweep measures the product and not a transcription of it.
#
# Exit: 0 all arms passed, 2 SKIP (no device), 1 a FAIL.
#
#   bash tools/profile_sweep_device.sh            # every builtin, 10 s each
#   SECS=20 bash tools/profile_sweep_device.sh    # longer per profile
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
out=${OUT:-$root/out/profile_sweep}
secs=${SECS:-10}
mkdir -p "$out"
rm -f "$out"/*.txt "$out"/*.log
export PATH="/c/msys64/ucrt64/bin:$root/dist/GamingScrcpy/scrcpy:$PATH"

# the packaged layout is the one a user runs, and it is the only one whose exe has
# the server asset beside it (a build-tree exe cannot start a session at all)
ROOT="$root"; . "$root/tools/layout.sh"
exe=""
for c in "$root/dist/GamingScrcpy/scrcpy/scrcpy.exe" \
         "$SRC/build-usb/app/scrcpy.exe"; do
    [ -f "$c" ] && [ -f "$(dirname "$c")/scrcpy-server" ] && { exe=$c; break; }
done
[ -n "$exe" ] || { echo 'SKIP  no scrcpy.exe with a scrcpy-server beside it'; exit 2; }

launcher=""
for c in "$root/dist/GamingScrcpy/launcher/GamingScrcpyLauncher.exe" \
         "$root/launcher/GamingScrcpyLauncher.exe"; do
    [ -f "$c" ] && { launcher=$c; break; }
done
[ -n "$launcher" ] || { echo 'SKIP  no GamingScrcpyLauncher.exe to dump the argv'; exit 2; }

adb="$root/dist/GamingScrcpy/scrcpy/adb.exe"
[ -x "$adb" ] || adb=adb
serial=${SERIAL:-}
if [ -z "$serial" ]; then
    serial=$("$adb" devices 2>/dev/null \
        | sed -n 's/^\([[:graph:]]*\)[[:space:]]*device$/\1/p' | head -1)
fi
[ -n "$serial" ] || { echo 'SKIP  no device attached (the sweep mirrors a real phone)'; exit 2; }

# Same rule as every other device arm of this project: a dark or locked panel
# starves the encoder, so a zero-telemetry verdict would describe a sleeping
# phone, not a broken profile. scrcpy's own MOD+O is the only wake allowed here.
wake_screen() {
    powershell -NoProfile -ExecutionPolicy Bypass \
        -File "$root/tools/wake_device_screen.ps1" 2>/dev/null \
        | grep -o 'RESULT wake.*' | tail -1
}
kill_scrcpy() { taskkill //F //IM scrcpy.exe >/dev/null 2>&1; sleep 1; }
count_scrcpy() { tasklist //FI "IMAGENAME eq scrcpy.exe" //NH 2>/dev/null \
    | grep -ci 'scrcpy\.exe'; }
# ask the window to close and wait: this is the "does it still answer" probe
stop_scrcpy() {
    taskkill //IM scrcpy.exe >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ "$(count_scrcpy)" -eq 0 ] && return 0
        sleep 1
    done
    return 1
}

printf 'device=%s exe=%s secs=%s\n' "$serial" "$exe" "$secs"
# relative --record paths are resolved by the client against its working directory:
# run the sweep inside out/ so a recording profile cannot drop a file in the repo
cd "$out" || exit 1
dump=$("$launcher" --dump-profile-args 2>&1)
n=$(printf '%s\n' "$dump" | sed -n 's/^DUMP OK n=\([0-9]*\).*/\1/p')
if [ -z "$n" ]; then
    echo 'FAIL  --dump-profile-args gave no DUMP OK line (old launcher exe? republish)'
    printf '%s\n' "$dump" | head -5
    exit 1
fi
# one argv file per profile, in the launcher's own order
printf '%s\n' "$dump" | awk -v d="$out" '
    /^NAME / { i++; f = d "/argv." i; print substr($0, 6) > (d "/name." i);
               printf "" > f; next }
    /^ARG /  { if (f != "") print substr($0, 5) >> f }
    /^END/   { close(f); f = "" }'
got=$(ls "$out"/argv.* 2>/dev/null | wc -l | tr -d ' ')
if [ "$got" -ne "$n" ]; then
    printf 'FAIL  dumped %s profile(s) but parsed %s argv file(s)\n' "$n" "$got"
    exit 1
fi

# preflight: prove this harness can drive this phone before judging 20 arms
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
    echo 'ABORT  the preflight painted no frame, so every arm below would fail for the wrong reason'
    sed -n '1,10p' "$out/preflight.txt"
    exit 1
fi
prefps=$(grep -o 'fps=[0-9.]\+' "$out/preflight.txt" | sed 's/fps=//' | sort -n \
    | awk '{v[NR]=$1} END{ if (NR) printf "%.1f", v[int((NR+1)/2)]; else print 0 }')
scene_live=1
awk -v f="$prefps" 'BEGIN{ exit !(f < 20) }' && scene_live=0
printf 'preflight ok (%s telemetry lines, fps_med=%s) %s scene=%s\n\n' \
    "$pre" "$prefps" "${wake:-no wake sent}" \
    "$( [ "$scene_live" = 1 ] && echo live || echo static )"
if [ "$scene_live" = 0 ]; then
    printf 'NOTE   the panel stayed dark or locked: arms that measure no frame are reported SKIP, not FAIL. Light and unlock the phone for a real sweep.\n\n'
fi

fails=0
skips=0
for i in $(seq 1 "$n"); do
    name=$(cat "$out/name.$i")
    # __SERIAL__ is the only placeholder the dump uses; every other token is copied verbatim
    argv=()
    while IFS= read -r line; do
        argv+=("${line/__SERIAL__/$serial}")
    done < "$out/argv.$i"
    log=$out/log.$i.txt
    kill_scrcpy
    "$exe" "${argv[@]}" > "$log" 2>&1 &
    sleep 3
    wake_screen > /dev/null
    sleep "$((secs - 3))"
    if stop_scrcpy; then
        closed=1
    else
        closed=0
        kill_scrcpy
    fi
    wait 2>/dev/null
    tel=$(grep -c 'telemetry:' "$log")
    fpsm=$(grep -o 'fps=[0-9.]\+' "$log" | sed 's/fps=//' | sort -n \
        | awk '{v[NR]=$1} END{ if (NR) printf "%.1f", v[int((NR+1)/2)]; else print 0 }')
    src=$(grep -o 'src=[0-9]*x[0-9]*' "$log" | tail -1)
    errl=$(grep -c '^ERROR' "$log")
    errs=$(grep '^ERROR' "$log" | head -2 | tr '\n' ' ')
    printf 'PROFILE %-34s telemetry=%s fps_med=%s %s errors=%s closed=%s\n' \
        "$name" "$tel" "${fpsm:-0}" "${src:-no-src}" "$errl" \
        "$( [ "$closed" = 1 ] && echo yes || echo NO )"
    if [ "$closed" = 0 ]; then
        printf '  FAIL %s would not close: a window that ignores WM_CLOSE is the "No responde" bug\n' "$name"
        fails=$((fails + 1))
    elif [ "$tel" -eq 0 ]; then
        if [ "$scene_live" = 1 ]; then
            printf '  FAIL %s painted no frame on a live panel: %s\n' "$name" "${errs:-no ERROR line}"
            fails=$((fails + 1))
        else
            printf '  SKIP %s measured nothing while the panel was dark\n' "$name"
            skips=$((skips + 1))
        fi
    else
        printf '  PASS %s mirrored %s s of frames%s\n' "$name" "$tel" \
            "$( [ "$errl" -gt 0 ] && printf ' (client reported: %s)' "$errs" )"
    fi
done

printf '\nRESULT profiles=%s fails=%s skips=%s scene=%s\n' "$n" "$fails" "$skips" \
    "$( [ "$scene_live" = 1 ] && echo live || echo static )"
[ "$fails" -eq 0 ] || exit 1
