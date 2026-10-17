#!/usr/bin/env bash
# One-shot verification suite for the GamingScrcpy fork + launcher.
# Every check is a real command against the built binaries; the script exits
# non-zero if any of them fails, so it can be used as a regression gate.
#
#   bash tools/verify_all.sh            # everything
#   bash tools/verify_all.sh --quick    # skip the named-pipe tests (PowerShell)

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# build-usb is what ships (AOA gamepad enabled); build-x is the -Dusb=false
# baseline kept from Phase 1/2.
BUILD="$ROOT/workspace/scrcpy/build-usb"
DIST="$ROOT/dist/GamingScrcpy"
DEMO="$BUILD/app/gamingdemo.exe"
SCRCPY="$DIST/scrcpy/scrcpy.exe"
LAUNCHER="$DIST/launcher/GamingScrcpyLauncher.exe"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

export PATH="/c/msys64/ucrt64/bin:$PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# expect the command to exit 0
accepts() {
    if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$* (exit $?)"; fi
}
# expect the command to exit non-zero (invalid input must be rejected)
rejects() {
    if "$@" >/dev/null 2>&1; then bad "$* (accepted, should not be)"; else ok "$*"; fi
}

head_ "1. build"
if ninja -C "$BUILD" >/dev/null 2>&1; then ok "ninja -C $(basename "$BUILD")"; else bad "ninja -C $(basename "$BUILD")"; fi
for f in "$SCRCPY" "$DIST/scrcpy/scrcpy-server.jar" "$DEMO" "$LAUNCHER"; do
    [ -f "$f" ] && ok "exists: ${f#$ROOT/}" || bad "missing: ${f#$ROOT/}"
done

head_ "2. packaged binary is self-contained (bare Windows PATH)"
if (cd "$DIST/scrcpy" && PATH="/c/Windows/system32" ./scrcpy.exe --version >/dev/null 2>&1); then
    ok "scrcpy.exe --version with only system32 in PATH"
else
    bad "scrcpy.exe needs DLLs from the build environment"
fi

head_ "3. every fork flag is accepted by the real parser"
accepts "$SCRCPY" --game-osd=none        --version
accepts "$SCRCPY" --game-osd=compact     --version
accepts "$SCRCPY" --game-osd=full        --version
accepts "$SCRCPY" --game-upscale=default --version
accepts "$SCRCPY" --game-upscale=nearest --version
accepts "$SCRCPY" --game-upscale=linear  --version
accepts "$SCRCPY" --game-upscale=pixelart --version
accepts "$SCRCPY" --game-postfx=none --version
accepts "$SCRCPY" --game-postfx=sharp,night,sat --version
accepts "$SCRCPY" --game-sharp=100 --version
accepts "$SCRCPY" --game-night-boost=100 --version
accepts "$SCRCPY" --game-saturation=200 --version
accepts "$SCRCPY" --game-contrast=200 --version
accepts "$SCRCPY" --game-brightness=0 --version
accepts "$SCRCPY" --game-gamma=25 --version
accepts "$SCRCPY" --game-postfx=contrast,brightness,gamma --version
accepts "$SCRCPY" --game-borderless-fullscreen --version
accepts "$SCRCPY" --game-low-latency --version
accepts "$SCRCPY" --game-cursor-autohide=60000 --version
accepts "$SCRCPY" --game-touch-visualizer --version
accepts "$SCRCPY" --game-frame-bridge="$TMP/f.raw" --version
accepts "$SCRCPY" --game-audio-bridge="$TMP/a.pcm" --version
accepts "$SCRCPY" --game-audio-pcm="$TMP/p.raw" --version
accepts "$SCRCPY" --game-bridge-scale=3840x2160 --version
accepts "$SCRCPY" --game-bridge-filter=lanczos --version
accepts "$SCRCPY" --game-window-filter=off --version
accepts "$SCRCPY" --game-window-filter=point --version
accepts "$SCRCPY" --game-window-filter=bilinear --version
accepts "$SCRCPY" --game-window-filter=fast --version
accepts "$SCRCPY" --game-window-filter=bicubic --version
accepts "$SCRCPY" --game-window-filter=lanczos --version
# --mouse-bind grammar, which the launcher exposes as free text
accepts "$SCRCPY" --mouse-bind=nbsh --version
accepts "$SCRCPY" --mouse-bind=bhsn:++++ --version
rejects "$SCRCPY" --mouse-bind=click=1,0 --version
rejects "$SCRCPY" --mouse-bind=abc --version

head_ "3b. an audio output counts as an audio consumer"
# Upstream turns the audio stream off when nothing plays or records it. Both
# fork outputs are consumers: without this the virtual cable would be silent
# in the --no-audio-playback configuration it exists for.
if "$SCRCPY" --no-audio-playback -x 2>&1 | grep -q "audio disabled"; then
    ok "baseline: --no-audio-playback alone disables audio"
else
    bad "expected 'audio disabled' with no audio consumer"
fi
if "$SCRCPY" --no-audio-playback --game-audio-pcm="$TMP/p.raw" -x 2>&1 \
        | grep -q "audio disabled"; then
    bad "--game-audio-pcm does not keep the audio stream alive"
else
    ok "--game-audio-pcm keeps audio alive without playback"
fi
if "$SCRCPY" --no-audio-playback --game-audio-bridge="$TMP/a.pcm" -x 2>&1 \
        | grep -q "audio disabled"; then
    bad "--game-audio-bridge does not keep the audio stream alive"
else
    ok "--game-audio-bridge keeps audio alive without playback"
fi

head_ "4. upstream tokens the launcher must emit correctly"
accepts "$SCRCPY" --render-driver=direct3d11 --version
accepts "$SCRCPY" --video-codec=h265 --version
accepts "$SCRCPY" --hwdec=d3d11va --version
accepts "$SCRCPY" --render-fit=letterbox --version
accepts "$SCRCPY" --shortcut-mod=lctrl,lalt,lsuper --version
accepts "$SCRCPY" --mouse=uhid --keyboard=sdk --gamepad=uhid --version
accepts "$SCRCPY" --gamepad=aoa --version
# upstream refuses AOA keyboard/mouse on Windows: adb already owns the USB
# device. Only the gamepad implementation opens its own AOA interface.
rejects "$SCRCPY" --keyboard=aoa --version
rejects "$SCRCPY" --mouse=aoa --version
rejects "$SCRCPY" --rendering-driver=direct3d11 --version
rejects "$SCRCPY" --video-codec=hevc --version
rejects "$SCRCPY" --hwdec=always --version
rejects "$SCRCPY" --render-fit=auto --version

head_ "4b. seeded keymaps only emit modes this build accepts"
km="${APPDATA:-}/GamingScrcpy/keymaps"
if [ -d "$km" ]; then
    checked=0
    badkm=0
    for f in "$km"/*.json; do
        [ -e "$f" ] || continue
        for key in KeyboardMode MouseMode GamepadMode MouseBindings; do
            v=$(sed -n "s/.*\"$key\": \"\([^\"]*\)\".*/\1/p" "$f")
            case "$v" in
                ""|auto) continue ;;
            esac
            flag=$(echo "$key" | sed -e 's/KeyboardMode/keyboard/' \
                       -e 's/MouseMode/mouse/' -e 's/GamepadMode/gamepad/' \
                       -e 's/MouseBindings/mouse-bind/')
            checked=$((checked+1))
            if ! "$SCRCPY" "--$flag=$v" --version >/dev/null 2>&1; then
                badkm=$((badkm+1))
                bad "$(basename "$f"): --$flag=$v rejected"
            fi
        done
    done
    [ "$badkm" -eq 0 ] && ok "$checked keymap mode(s) accepted by scrcpy"
else
    bad "keymap directory not found (start the launcher once to seed it)"
fi

head_ "5. bad input is rejected, not ignored"
rejects "$SCRCPY" --game-osd=bogus --version
rejects "$SCRCPY" --game-upscale=best --version
rejects "$SCRCPY" --game-sharp=150 --version
rejects "$SCRCPY" --game-saturation=300 --version
rejects "$SCRCPY" --game-contrast=300 --version
rejects "$SCRCPY" --game-brightness=300 --version
rejects "$SCRCPY" --game-gamma=24 --version
rejects "$SCRCPY" --game-cursor-autohide=abc --version
rejects "$SCRCPY" --game-bridge-scale=12x99 --version
rejects "$SCRCPY" --game-bridge-filter=kaiser --version
rejects "$SCRCPY" --game-window-filter=kaiser --version
rejects "$SCRCPY" --game-window-filter=2 --version
rejects "$SCRCPY" --game-postfx=blur --version

head_ "6. presentation engine, file bridge with host resample"
out="$TMP/scale.raw"
if "$DEMO" --frames=24 --width=720 --height=1280 --fx \
        --bridge="$out" --bridge-scale=1920x1080 --bridge-filter=lanczos \
        --no-osd >"$TMP/scale.log" 2>&1; then
    ok "gamingdemo exit 0"
    if grep -q 'gamingdemo: PASS' "$TMP/scale.log"; then ok "self-check PASS"; else bad "self-check FAIL"; fi
    bytes=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ $((bytes % (1920*1080*4))) -eq 0 ] && [ "$bytes" -gt 0 ]; then
        ok "bridged size $bytes is a whole number of 1920x1080 RGBA frames"
    else
        bad "bridged size $bytes is not a multiple of $((1920*1080*4))"
    fi
    grep -q 'postfx cpu cost' "$TMP/scale.log" && ok "postfx cost measured" || bad "no postfx measurement"
else
    bad "gamingdemo run failed"
fi

head_ "7. presentation engine, stdout bridge + OSD + touch visualizer"
if "$DEMO" --frames=20 --width=480 --height=640 --bridge=- --audio=- --no-osd \
        >"$TMP/std.log" 2>/dev/null; then
    ok "gamingdemo over stdout"
else
    bad "gamingdemo over stdout"
fi
if "$DEMO" --frames=20 --width=480 --height=640 --shot="$TMP/shot.bmp" >/dev/null 2>&1; then
    [ -s "$TMP/shot.bmp" ] && ok "frame captured with overlay ($(stat -c %s "$TMP/shot.bmp") B)" || bad "screenshot empty"
else
    bad "gamingdemo with OSD failed"
fi

head_ "7b. window path resample (--game-window-filter) tracks the window"
wflog="$TMP/wf.log"
wfraw="$TMP/wf.raw"
if "$DEMO" --frames=30 --width=720 --height=1280 --fx --window-filter=lanczos \
        --bridge="$wfraw" --bridge-scale=640x360 --no-osd >"$wflog" 2>&1; then
    ok "gamingdemo with --window-filter=lanczos"
    if grep -q 'gamingdemo: PASS' "$wflog"; then ok "window filter self-check PASS"; else bad "window filter self-check FAIL"; fi
    line=$(grep -o 'window filter 720x1280 -> .*tex_rebuilds=[0-9]*' "$wflog" | tail -1)
    if [ -n "$line" ]; then ok "$line"; else bad "no window filter report line"; fi
    # a resized window must produce more than one presented size
    if grep -q 'distinct=[2-9]' "$wflog"; then
        ok "presented picture followed the window resize"
    else
        bad "presented size never changed (window filter is static)"
    fi
    # the frame bridge must still carry the device-size frames, scaled only by
    # its own --bridge-scale, never by the window filter
    bytes=$(stat -c %s "$wfraw" 2>/dev/null || echo 0)
    if [ "$bytes" -gt 0 ] && [ $((bytes % (640*360*4))) -eq 0 ]; then
        ok "frame bridge unaffected ($bytes B of 640x360 RGBA frames)"
    else
        bad "frame bridge disturbed by the window filter: $bytes B"
    fi
    # the OSD must keep rendering (it reports the WIN state) with the filter on
    if "$DEMO" --frames=20 --width=480 --height=640 --window-filter=bicubic \
            --shot="$TMP/wf.bmp" >/dev/null 2>&1; then
        [ -s "$TMP/wf.bmp" ] && ok "OSD + window filter frame captured ($(stat -c %s "$TMP/wf.bmp") B)" || bad "window filter screenshot empty"
    else
        bad "gamingdemo with OSD + window filter failed"
    fi
else
    bad "gamingdemo with --window-filter failed"
fi

head_ "7c. every GPU render backend presents the same path"
rd="$(bash "$ROOT/tools/render_driver_test.sh" 30 2>&1)"
code=$?
if [ "$code" -eq 0 ] && printf '%s' "$rd" | grep -qx 'OK'; then
    while IFS= read -r line; do ok "$line"; done \
        <<< "$(printf '%s' "$rd" | grep '^RESULT')"
else
    bad "render backend sweep failed"
    printf '%s\n' "$rd" | sed 's/^/        /'
fi

head_ "7d. the OSD telemetry reports live values, not zeros"
te="$TMP/telemetry.log"
"$DEMO" --frames=150 --width=480 --height=640 > "$te" 2>&1
tf="$(sed -n 's/.*telemetry fps=\([0-9.]*\).*/\1/p' "$te" | head -1)"
kb="$(sed -n 's/.*video=\([0-9]*\) KB\/s.*/\1/p' "$te" | head -1)"
pf="$(sed -n 's/.*fps(present)=\([0-9.]*\).*/\1/p' "$te" | head -1)"
if awk -v v="${tf:-0}" 'BEGIN { exit !(v > 30) }' \
   && awk -v k="${kb:-0}" -v f="${tf:-0}" \
        'BEGIN { e = 1012.5 * f; exit !(k > e * 0.6 && k < e * 1.4) }'; then
    # the demo feeds exactly 1920*1080/2 B per frame, so the reported rate is
    # predictable: a 1000x unit error (µs vs ms) fails here instead of passing a
    # "greater than zero" test, which is exactly how the bug shipped once.
    ok "OSD telemetry computes fps=${tf} video=${kb} KB/s (expected ~$(awk -v f="$tf" 'BEGIN { printf "%.0f", 1012.5 * f }') KB/s)"
else
    bad "OSD telemetry is wrong or zero (fps=${tf:-none} video=${kb:-none} KB/s, expected ~1012.5*fps KB/s)"
fi
if awk -v v="${pf:-0}" 'BEGIN { exit !(v > 30) }'; then
    ok "presentation rate measured from the loop: fps(present)=${pf}"
else
    bad "fps(present)=${pf:-none} while frames were presented"
fi

if [ "$QUICK" -eq 0 ]; then
    head_ "8. named-pipe transports (real pipe consumer, PowerShell)"
    ps() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$1" 2>&1; }
    p1="$(ps "$ROOT/tools/bridge_pipe_test.ps1")"
    n_true=$(printf '%s' "$p1" | grep -c 'exact_multiple=True')
    if [ "$n_true" -ge 2 ]; then
        ok "frame bridge over pipe: $n_true transports byte-exact"
    else
        bad "frame bridge over pipe: only $n_true byte-exact cases"
    fi
    printf '%s' "$p1" | grep -q 'no consumer' && ok "no-consumer case reported" || bad "no-consumer case missing"
    p2="$(ps "$ROOT/tools/bridge_audio_pipe_test.ps1")"
    got2="$(printf '%s' "$p2" | grep '^pipe consumer received' | head -1)"
    retry2=''
    if ! printf '%s' "$p2" | grep -q '80000 400'; then
        # Same flake family as the windowed sections: a busy desktop makes the
        # writer drop chunks before the consumer connects, so retry once and
        # label it instead of letting a silent rerun be the workaround.
        retry2=' [passed on the retry]'
        p2="$(ps "$ROOT/tools/bridge_audio_pipe_test.ps1")"
        got2="$(printf '%s' "$p2" | grep '^pipe consumer received' | head -1)"
    fi
    if printf '%s' "$p2" | grep -q '80000 400'; then
        ok "audio bridge over pipe: ${got2:-no line}${retry2}"
    else
        bad "audio bridge over pipe: ${got2:-no line} (expected '80000 400')"
    fi
    p3="$(ps "$ROOT/tools/pcm_tap_pipe_test.ps1")"
    if printf '%s' "$p3" | grep -qx 'PCMPIPE OK'; then
        ok "$(printf '%s' "$p3" | grep '^pipe consumer received')"
        printf '%s' "$p3" | grep -q 'max_volume' && \
            ok "$(printf '%s' "$p3" | grep '^ffmpeg decoded the piped bytes')" || \
            bad "pcm tap over pipe: not decoded by ffmpeg"
    else
        bad "pcm tap over pipe failed"
        printf '%s\n' "$p3" | sed 's/^/        /'
    fi
fi

head_ "8b. both bridges feed a real encoder (ffmpeg) and stay in duration"
enc="$(bash "$ROOT/tools/bridge_encode_test.sh" 40 320x180 2>&1)"
code=$?
retried=0
# fps(present) counts the frames actually handed to the GPU, so 0.0 means the
# window presented nothing at all -- the documented "desktop still busy with a
# GPU or disk burst" case. Retry once and label the attempt instead of reporting
# a silent pass or a fake regression. (Before the demo counted real presents this
# line read 0.0 for every run without --fx, so the condition matched any failure;
# section 7d now asserts a nonzero rate on a healthy run.)
if [ "$code" -ne 0 ] && [ "$code" -ne 77 ] \
        && printf '%s' "$enc" | grep -q 'fps(present)=0.0'; then
    sleep 10
    enc="$(bash "$ROOT/tools/bridge_encode_test.sh" 40 320x180 2>&1)"
    code=$?
    retried=1
fi
if [ "$code" -eq 77 ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "$(printf '%s' "$enc" | tail -1)"
elif printf '%s' "$enc" | grep -qx 'OK'; then
    [ "$retried" -eq 0 ] || \
        ok "encoder round-trip passed on the retry (the first attempt presented 0 frames)"
    ok "$(printf '%s' "$enc" | grep '^RESULT codecs')"
    ok "$(printf '%s' "$enc" | grep '^RESULT mp4')"
    ok "$(printf '%s' "$enc" | grep '^RESULT pcm_tap')"
else
    bad "encoder round-trip failed"
    printf '%s\n' "$enc" | sed 's/^/        /'
fi

head_ "8c. recorder integrity with no device attached"
rec="$(bash "$ROOT/tools/recorder_integrity_test.sh" 30 320x180 2>&1)"
code=$?
if [ "$code" -eq 77 ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "$(printf '%s' "$rec" | tail -1)"
elif printf '%s' "$rec" | grep -qx 'OK'; then
    while IFS= read -r line; do ok "$line"; done \
        <<< "$(printf '%s' "$rec" | grep '^RESULT')"
else
    bad "recorder integrity failed"
    printf '%s\n' "$rec" | sed 's/^/        /'
fi

head_ "8d. the shipped package verifies itself (no build tree, no phone)"
if [ -d "$DIST/tools" ] && [ -f "$DIST/scrcpy/recorderintegrity.exe" ]; then
    prec="$(cd "$DIST" && bash tools/recorder_integrity_test.sh 30 320x180 2>&1)"
    pcode=$?
    if [ "$pcode" -eq 77 ]; then
        printf '  \033[33mSKIP\033[0m  %s\n' "$(printf '%s' "$prec" | tail -1)"
    elif printf '%s' "$prec" | grep -qx 'OK'; then
        ok "$(printf '%s' "$prec" | grep -c '^RESULT') recorder cases through the shipped harness"
    else
        bad "the packaged recorder check failed"
        printf '%s\n' "$prec" | sed 's/^/        /'
    fi
else
    printf '  \033[33mSKIP\033[0m  package layout not assembled\n'
fi

head_ "9. launcher profile self-test (generated args vs the real binary)"
if [ -x "$LAUNCHER" ] || [ -f "$LAUNCHER" ]; then
    lv="$("$LAUNCHER" --validate-profiles 2>&1)"
    if printf '%s' "$lv" | grep -q 'ALL PROFILES VALID'; then
        ok "$(printf '%s' "$lv" | grep -c '^PASS') profile(s) valid"
    else
        bad "profile validation failed"
        printf '%s\n' "$lv" | tail -5
    fi
    printf '%s' "$lv" | grep -q -- '--game-bridge-scale=' && ok "bridge scale emitted by the launcher" || bad "launcher does not emit --game-bridge-scale"
    printf '%s' "$lv" | grep -q -- '--game-window-filter=' && ok "window kernel emitted by the launcher" || bad "launcher does not emit --game-window-filter"
    printf '%s' "$lv" | grep -q -- '--game-audio-pcm=' && ok "PCM tap emitted by the launcher" || bad "launcher does not emit --game-audio-pcm"
    printf '%s' "$lv" | grep -q -- '--no-audio-playback' && ok "mute-PC option emitted by the launcher" || bad "launcher does not emit --no-audio-playback"
    printf '%s' "$lv" | grep -q 'synthetic max settings' && ok "synthetic all-controls profile checked" || bad "synthetic profile missing from the self-test"
else
    bad "launcher not found"
fi

head_ "10. launcher UI tree (every gaming control reaches the live window)"
if [ "$QUICK" -eq 1 ]; then
    printf '  \033[33mSKIP\033[0m  UI automation (needs a desktop session)\n'
else
    ua="$(powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File "$ROOT/tools/launcher_uiauto.ps1" 2>&1)"
    if printf '%s' "$ua" | grep -qx 'UIAUTO OK'; then
        ok "$(printf '%s' "$ua" | grep -c '^PASS') configurator controls present in the running window"
    else
        bad "launcher UI tree incomplete"
        printf '%s\n' "$ua" | sed 's/^/        /'
    fi
fi

head_ "11. the launcher drives a real device (skipped when none is connected)"
# Everything above is device-free on purpose; this one section is not, and it is
# the only check that can notice a packaged client that cannot start a session
# (the portable-server bug of 5.1l was exactly that). It clicks Mirror in the
# live GUI and asserts the child process and its --serial.
devcount="$("$ROOT/dist/GamingScrcpy/launcher/adb.exe" devices 2>/dev/null | grep -c '[[:space:]]device$')"
if [ "${devcount:-0}" -eq 0 ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "no adb device attached, launcher end-to-end not exercised"
else
    dt="$(powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File "$ROOT/tools/launcher_device_test.ps1" 2>&1)"
    if printf '%s' "$dt" | grep -qx 'OK'; then
        while IFS= read -r line; do ok "$line"; done \
            <<< "$(printf '%s' "$dt" | grep '^RESULT')"
    else
        bad "launcher did not drive the connected device"
        printf '%s\n' "$dt" | sed 's/^/        /'
    fi
fi

head_ "12. measured host-side mirror latency on a real device (skipped when none is connected)"
# The one number §5 phase 4 asks for and that no host-only harness can produce.
# --game-telemetry-log reports recv->present per frame, so this section prints
# percentiles instead of a claim. It asserts only that the mirror measured
# *something*; the values belong to the report, since they depend on the GPU,
# the cable and what happens to be on screen.
if [ "${devcount:-0}" -eq 0 ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "no adb device attached, latency not measured"
else
    lp="$(bash "$ROOT/tools/device_latency_probe.sh" 2>&1)"
    if printf '%s' "$lp" | grep -qx 'OK'; then
        while IFS= read -r line; do ok "$line"; done \
            <<< "$(printf '%s' "$lp" | grep '^RESULT')"
        while IFS= read -r line; do printf '        %s\n' "$line"; done \
            <<< "$(printf '%s' "$lp" | grep 'telemetry-summary')"
    else
        bad "device latency probe failed"
        printf '%s\n' "$lp" | sed 's/^/        /'
    fi
fi

head_ "13. touch alignment is still upstream code (the project's core constraint)"
# §1 of the directive forbids anything that could shift touch alignment. The
# mapping lives in screen.c: compute_content_rect() plus the pointer conversions
# read screen->rect. The fork draws its overlays *into* that rect and never
# recomputes it -- assert that instead of trusting it, because a future change
# to the OSD, the borderless mode or the window filter could silently break it.
SRC="$ROOT/workspace/scrcpy"
if [ ! -d "$SRC/.git" ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "no git checkout here (packaged layout)"
else
    base="$(git -C "$SRC" describe --tags --abbrev=0 2>/dev/null)"
    diff_screen="$(git -C "$SRC" diff "$base" -- app/src/screen.c 2>/dev/null)"
    if [ -z "$base" ] || [ -z "$diff_screen" ]; then
        bad "no upstream baseline to compare screen.c against"
    else
        touched_map="$(printf '%s\n' "$diff_screen" \
                       | grep -Ec '^[+-].*(compute_content_rect|convert_to_screen_coords|convert_from_screen_coords|is_optimal_size)')"
        writes_rect="$(printf '%s\n' "$diff_screen" \
                       | grep -E '^\+' \
                       | grep -Ec 'screen->rect[[:space:]]*=[^=]|rect->(x|y|w|h)[[:space:]]*=[^=]')"
        hunks="$(printf '%s\n' "$diff_screen" | sed -n 's/^@@[^@]*@@ \(.*\)$/\1/p' \
                 | cut -d'(' -f1 | sort -u | tr '\n' ' ')"
        if [ "$touched_map" -eq 0 ] && [ "$writes_rect" -eq 0 ]; then
            ok "screen.c changes nothing in the mapping path vs $base (hunks only in: $hunks)"
        else
            bad "the pointer mapping changed (mapping lines=$touched_map rect writes=$writes_rect)"
        fi
        # the device must keep being captured at its own size: no flag may send
        # a resolution or a display to the server. Look for them inside the
        # argument strings (a leading quote), not in the explanatory comment
        # that says the same thing.
        dev_res="$(grep -Ern -- '"--max-size|"--crop|"--new-display|"--display-id' \
                    "$ROOT/launcher" --include="*.cs" --include="*.xaml" \
                    --include="*.json" 2>/dev/null | grep -vE '/obj/|/bin/' | wc -l)"
        control="$(grep -Ern -- '"--serial' "$ROOT/launcher" --include="*.cs" \
                    2>/dev/null | grep -vE '/obj/|/bin/' | wc -l)"
        if [ "${control:-0}" -eq 0 ]; then
            bad "the launcher argument scan found no --serial either (scan is broken)"
        elif [ "${dev_res:-0}" -eq 0 ]; then
            ok "the launcher emits no device-side resolution/crop/display flag (control: --serial present)"
        else
            bad "the launcher sets a device-side resolution/crop/display flag ($dev_res hits)"
        fi
    fi
fi

head_ "14. no script, launcher or test of this project writes to the device (directive §4.2)"
# The tablet is somebody's real phone, so streaming and input injection aside,
# nothing shipped here may install, push, or change a device setting. Patterns
# bracket their first letter so that this gate file never matches its own list.
# Upstream scrcpy legitimately implements the IDL installer and the TCP
# reconnect, so app/ is scanned only for lines this fork *added* -- scanning it
# wholesale would fail on code we did not write.
WRITE_PATTERNS='[aA]db install|[aA]db uninstall|[aA]db push|[aA]db root|[aA]db remount|[aA]db reboot|[aA]db tcpip|[aA]db usb|[sS]ettings put|[sS]ettings delete|[sS]ettings secure|[wW]m size|[wW]m density|[wW]m overscan|[pP]m install|[pP]m uninstall|[pP]m clear|\b[aA]m force-stop|\b[aA]m start|\b[aA]m kill|[fF]astboot '
our_dirs=()
for d in scripts tools launcher; do
    [ -d "$ROOT/$d" ] && our_dirs+=("$ROOT/$d")
done
fixture="$ROOT/tools/fixtures/device_write_adb_install.sh"
if [ "${#our_dirs[@]}" -eq 0 ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "no project source dirs here (packaged layout)"
else
    # positive control first: a grep that matches nothing would pass everything
    fixture_hits="$(grep -cE "$WRITE_PATTERNS" "$fixture" 2>/dev/null)"
    if [ "${fixture_hits:-0}" -lt 3 ]; then
        bad "the blacklist fixture is not detected (hits=${fixture_hits:-0}/3, grep is broken)"
    else
        ok "blacklist grep detects the 3 forbidden commands in the fixture (positive control)"
    fi
    control="$(grep -rlE 'shell getprop' "$ROOT/launcher" --include='*.cs' 2>/dev/null | wc -l)"
    if [ "${control:-0}" -eq 0 ]; then
        bad "the launcher scan saw no read-only call either, so the scan path is wrong"
    else
        ok "the scan really covers the launcher sources (control: getprop found)"
    fi
    hits="$(grep -rnE --binary-files=without-match \
              --exclude-dir=fixtures --exclude-dir=platform-tools --exclude-dir=stock \
              --exclude-dir=bin --exclude-dir=obj --exclude-dir=out \
              "$WRITE_PATTERNS" "${our_dirs[@]}" 2>/dev/null)"
    if [ -z "$hits" ]; then
        ok "our scripts/tools/launcher contain no device write command (${#our_dirs[@]} dirs scanned)"
    else
        bad "device write commands found in project code ($(printf '%s\n' "$hits" | wc -l) hits)"
        printf '%s\n' "$hits" | head -10 | sed 's/^/        /'
    fi
    if [ -d "$SRC/.git" ]; then
        base="${base:-$(git -C "$SRC" describe --tags --abbrev=0 2>/dev/null)}"
        added="$(git -C "$SRC" diff "$base" -- app 2>/dev/null | grep '^+' | grep -v '^+++')"
        fork_hits="$(printf '%s\n' "$added" | grep -cE "$WRITE_PATTERNS")"
        if [ -z "$base" ]; then
            printf '  \033[33mSKIP\033[0m  %s\n' "no upstream baseline to diff app/ against"
        elif [ "${fork_hits:-0}" -eq 0 ]; then
            ok "the fork adds no device write command to app/ ($(printf '%s\n' "$added" | wc -l) added lines checked)"
        else
            bad "the fork added $fork_hits device write line(s) in app/"
            printf '%s\n' "$added" | grep -E "$WRITE_PATTERNS" | head -10 | sed 's/^/        /'
        fi
    fi
fi

head_ "15. the launcher has no untranslated text left (directive v2 §B)"
# The static half of the i18n contract: every key the XAML asks for must exist
# in the Loc table, no key may be declared twice, and no user-visible string may
# be built in the code-behind. The runtime half -- an empty translation column
# renders as "??? key" -- is asserted by the UI Automation audit above, which
# switches language and reads the labels back.
LOCSRC="$ROOT/launcher/Loc.cs"
locfk="$ROOT/tools/fixtures"
if [ ! -f "$LOCSRC" ] || [ ! -d "$locfk" ]; then
    printf '  \033[33mSKIP\033[0m  %s\n' "no launcher sources here (packaged layout)"
else
    loc_keys="$(sed -n 's/^[[:space:]]*new\[\] { "\([^"]*\)".*/\1/p' "$LOCSRC" | sort -u)"
    loc_rows="$(sed -n 's/^[[:space:]]*new\[\] { "\([^"]*\)".*/\1/p' "$LOCSRC" | wc -l)"
    if [ "$(printf '%s\n' "$loc_keys" | wc -l)" -ne "$loc_rows" ]; then
        bad "the Loc table declares duplicate keys ($(printf '%s\n' "$loc_keys" | wc -l) unique of $loc_rows rows)"
    else
        ok "the Loc table declares $loc_rows unique keys"
    fi

    # one helper, used for both the real XAML and the fixture, so the control
    # proves *this* comparison works rather than a copy of it
    missing_keys() {
        grep -ohE '\{DynamicResource [A-Za-z0-9_]+' "$@" 2>/dev/null \
            | awk '{print $2}' | sort -u \
            | while read -r k; do
                  printf '%s\n' "$loc_keys" | grep -qx -- "$k" || printf '%s\n' "$k"
              done
    }
    ctrl="$(missing_keys "$locfk/localization_missing_key.txt" | wc -l)"
    if [ "${ctrl:-0}" -ne 2 ]; then
        bad "the key checker does not flag the 2 missing keys in the fixture (got ${ctrl:-0})"
    else
        ok "the key checker flags the fixture's 2 unknown keys (positive control)"
    fi
    live="$(missing_keys "$ROOT/launcher/MainWindow.xaml" "$ROOT/launcher/App.xaml")"
    refs="$(grep -ohE '\{DynamicResource [A-Za-z0-9_]+' "$ROOT/launcher/MainWindow.xaml" \
             "$ROOT/launcher/App.xaml" 2>/dev/null | wc -l)"
    if [ -z "$live" ]; then
        ok "all $refs DynamicResource references in the XAML exist in Loc"
    else
        bad "the XAML asks for keys Loc does not define:"
        printf '%s\n' "$live" | sed 's/^/        /'
    fi

    LIT_RE='Log\(\$?"[A-Za-z]|MessageBox\.Show\(this, *"'
    lit_ctrl="$(grep -cE "$LIT_RE" "$locfk/localization_literal_log.cs")"
    if [ "${lit_ctrl:-0}" -lt 1 ]; then
        bad "the hardcoded-string scan does not match the fixture (scan is broken)"
    else
        ok "the hardcoded-string scan matches the fixture (positive control)"
    fi
    lits="$(grep -nE "$LIT_RE" "$ROOT/launcher/MainWindow.xaml.cs" \
             "$ROOT/launcher/MainWindow.Localized.cs" 2>/dev/null)"
    if [ -z "$lits" ]; then
        ok "no user-visible literal left in the code-behind"
    else
        bad "user-visible strings are hardcoded in the code-behind:"
        printf '%s\n' "$lits" | sed 's/^/        /'
    fi
fi

head_ "16. host filter pixels (tools/fx_pixel_test.sh)"
# A colour grade is only worth shipping if each control moves the picture, so
# the assertions run as their own harness: a deterministic test pattern, one
# filter enabled at a time, luma/chroma statistics before and after, and a PNG
# dump per case. The harness carries its own controls (an identity run with no
# filter, plus the neutral 100% setting of each grade), which is what makes a
# green line here mean something instead of a passing grep.
fxlog="$TMP/fx_pixel.log"
if bash "$ROOT/tools/fx_pixel_test.sh" > "$fxlog" 2>&1; then
    ok "filter pixel assertions: $(grep -c '^PASS' "$fxlog") checks passed"
else
    bad "filter pixel assertions failed:"
    grep -E '^FAIL' "$fxlog" | head -12
fi

printf '\n\033[1m%s\033[0m\n' "summary"
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
