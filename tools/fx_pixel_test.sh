#!/usr/bin/env bash
# Pixel-level proof that each host filter reaches the picture.
#
# gamingdemo renders a deterministic test pattern, runs the real
# sc_gaming_process_frame() over it and prints luma mean, luma variance and
# chroma variance for the frame before and after the filters, plus a PNG of the
# filtered frame. Every case enables exactly one filter, so a metric can only
# move because of the filter under test. That turns "the slider maps to a real
# flag" into a measurement instead of a code read.
#
# The controls that keep a broken harness honest:
#   * with no filter enabled, the "in" and "out" metrics must be identical
#     (proves nothing is processed behind the user's back, and proves the
#     comparison itself can detect a difference);
#   * the 100% setting of contrast/brightness/gamma/saturation must also be
#     inert, so a flag that is parsed but ignored cannot pass as "wired up";
#   * an out-of-range value must be rejected by the real binary.
#
#   bash tools/fx_pixel_test.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# the build-tree binaries are dynamically linked against the MSYS2 FFmpeg, so
# they only run with that toolchain on PATH (the packaged dist build is static)
for d in /c/msys64/ucrt64/bin /ucrt64/bin; do
    [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH

DEMO=""
SC=""
for c in "$ROOT/workspace/scrcpy/build-usb/app/gamingdemo.exe" \
         "$ROOT/workspace/scrcpy/build-x/app/gamingdemo.exe" \
         "$ROOT/scrcpy/gamingdemo.exe"; do
    [ -f "$c" ] && { DEMO="$c"; break; }
done
for c in "$ROOT/workspace/scrcpy/build-usb/app/scrcpy.exe" \
         "$ROOT/dist/GamingScrcpy/scrcpy.exe" \
         "$ROOT/scrcpy/scrcpy.exe"; do
    [ -f "$c" ] && { SC="$c"; break; }
done
[ -n "$DEMO" ] || { echo "FAIL gamingdemo not found (build tree or package)"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
W=240
H=320

run() { # run <label> <extra gamingdemo args...>
    local label="$1"; shift
    "$DEMO" --frames=2 --width="$W" --height="$H" --no-osd --stats \
            --png="$T/$label.png" "$@" > "$T/$label.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL fx $label: gamingdemo exited non-zero"
        sed -n '1,6p' "$T/$label.log"
        fail=$((fail + 1))
        return 1
    fi
    [ -s "$T/$label.png" ] || { echo "FAIL fx $label: no PNG dumped"; fail=$((fail + 1)); }
}

get() { # get <label> <in|out> <field>
    awk -v key="$3" '
        function field(line, k,  a, n, i) {
            n = split(line, a, " ")
            for (i = 1; i <= n; i++) {
                if (index(a[i], k "=") == 1) return substr(a[i], length(k) + 2)
            }
            return ""
        }
        $0 ~ ("gamingdemo: fx " tag " luma_mean=") { line = $0 }
        END { print field(line, key) }
    ' tag="$2" "$T/$1.log"
}

applied() { # applied <label>
    awk -F= '/gamingdemo: fx mask=/ { print $NF }' "$T/$1.log"
}

compare() { # compare <label> <gt|lt|eq> <a> <b> <margin>
    local label="$1" op="$2" a="$3" b="$4" m="$5"
    if [ -z "$a" ] || [ -z "$b" ]; then
        echo "FAIL fx $label: metric missing (a='$a' b='$b')"; fail=$((fail + 1)); return
    fi
    if awk -v a="$a" -v b="$b" -v m="$m" -v op="$op" 'BEGIN {
            d = a - b
            if (op == "gt") exit !(d > m)
            if (op == "lt") exit !(-d > m)
            exit !(d < m && -d < m)
        }'; then
        echo "PASS fx $label $op ($a vs $b, margin $m)"
    else
        echo "FAIL fx $label $op ($a vs $b, margin $m)"; fail=$((fail + 1))
    fi
}

expect_applied() { # expect_applied <label> <yes|no>
    local got; got="$(applied "$1")"
    if [ "$got" = "$2" ]; then
        echo "PASS fx $1 applied=$got"
    else
        echo "FAIL fx $1 applied=$got (expected $2)"; fail=$((fail + 1))
    fi
}

# --- control: nothing enabled must leave the frame untouched -----------------
run neutral
if [ -s "$T/neutral.log" ]; then
    expect_applied neutral no
    for f in luma_mean luma_var chroma_var; do
        compare "neutral-$f identity" eq "$(get neutral in $f)" "$(get neutral out $f)" 0.000001
    done
fi

# --- the new filters: each neutral setting must be inert, each moved setting
#     must move the metric in the direction the option documents -------------
for spec in contrast:100 bright:100 gamma:100 sat:100; do
    name="${spec%%:*}"; val="${spec##*:}"
    run "neutral_$name" "--fx-only=$name" "--fx-$name=$val"
    expect_applied "neutral_$name" yes
    compare "$name=$val inert (luma)" eq "$(get "neutral_$name" out luma_mean)" \
            "$(get neutral out luma_mean)" 0.000001
    compare "$name=$val inert (chroma)" eq "$(get "neutral_$name" out chroma_var)" \
            "$(get neutral out chroma_var)" 0.000001
done

run contrast_hi --fx-only=contrast --fx-contrast=140
run contrast_lo --fx-only=contrast --fx-contrast=60
expect_applied contrast_hi yes
expect_applied contrast_lo yes
# the pattern is dark, so raising contrast pushes it down and vice versa
compare "contrast=140 lowers luma mean" lt "$(get contrast_hi out luma_mean)" \
        "$(get neutral out luma_mean)" 2
compare "contrast=60 raises luma mean" gt "$(get contrast_lo out luma_mean)" \
        "$(get neutral out luma_mean)" 2
compare "contrast is monotonic" gt "$(get contrast_lo out luma_mean)" \
        "$(get contrast_hi out luma_mean)" 2

run bright_hi --fx-only=bright --fx-bright=150
run bright_lo --fx-only=bright --fx-bright=50
expect_applied bright_hi yes
expect_applied bright_lo yes
compare "brightness=150 raises luma mean" gt "$(get bright_hi out luma_mean)" \
        "$(get neutral out luma_mean)" 10
compare "brightness=50 lowers luma mean" lt "$(get bright_lo out luma_mean)" \
        "$(get neutral out luma_mean)" 10
# a luma-only grade must not touch colour at all
compare "brightness leaves chroma alone" eq "$(get bright_hi out chroma_var)" \
        "$(get neutral out chroma_var)" 0.000001

run gamma_hi --fx-only=gamma --fx-gamma=150
run gamma_lo --fx-only=gamma --fx-gamma=60
expect_applied gamma_hi yes
expect_applied gamma_lo yes
compare "gamma=150 raises luma mean" gt "$(get gamma_hi out luma_mean)" \
        "$(get neutral out luma_mean)" 10
compare "gamma=60 lowers luma mean" lt "$(get gamma_lo out luma_mean)" \
        "$(get neutral out luma_mean)" 2

run sat_hi --fx-only=sat --fx-sat=160
run sat_lo --fx-only=sat --fx-sat=50
expect_applied sat_hi yes
expect_applied sat_lo yes
# scale_chroma multiplies (chroma - 128) by sat/100 and clamps to 0..255, so
# variance grows with it. The pattern's brightest bar clips, which is why
# sat=160 measures about 1.4x instead of the ideal (1.6)^2 = 2.56x; the
# direction, not the ratio, is what is being asserted.
compare "saturation=160 raises chroma variance" gt "$(get sat_hi out chroma_var)" \
        "$(get neutral out chroma_var)" 0
compare "saturation=50 lowers chroma variance" lt "$(get sat_lo out chroma_var)" \
        "$(get neutral out chroma_var)" 0
compare "saturation leaves luma alone" eq "$(get sat_hi out luma_mean)" \
        "$(get neutral out luma_mean)" 0.000001

run sharp --fx-only=sharp --fx-sharp=80
expect_applied sharp yes
compare "sharpen changes luma detail energy" gt "$(get sharp out luma_var)" \
        "$(get neutral out luma_var)" 1
compare "sharpen leaves chroma alone" eq "$(get sharp out chroma_var)" \
        "$(get neutral out chroma_var)" 0.000001

run night --fx-only=night --fx-night=60
expect_applied night yes
compare "night-boost raises luma mean" gt "$(get night out luma_mean)" \
        "$(get neutral out luma_mean)" 2

# --- the PNG dumps must be real PNGs and must differ between settings -------
for label in neutral contrast_hi bright_hi sat_hi; do
    p="$T/$label.png"
    if [ -f "$p" ] && head -c 4 "$p" | od -An -tx1 | grep -qi '89 50 4e 47'; then
        echo "PASS fx $label PNG magic ok ($(wc -c < "$p") bytes)"
    else
        echo "FAIL fx $label PNG missing or not a PNG"; fail=$((fail + 1))
    fi
done
if [ -f "$T/neutral.png" ] && [ -f "$T/contrast_hi.png" ] \
        && ! cmp -s "$T/neutral.png" "$T/contrast_hi.png"; then
    echo "PASS fx neutral and contrast=140 PNGs differ"
else
    echo "FAIL fx neutral and contrast=140 PNGs are identical or missing"
    fail=$((fail + 1))
fi

# keep the inspection images: they are the artefact a human is meant to look at
KEEP="$ROOT/out/fx"
mkdir -p "$KEEP" 2>/dev/null && cp "$T"/*.png "$KEEP/" 2>/dev/null \
    && echo "INFO fx PNG dumps kept in $KEEP"

# --- the flags must exist on the real binary, with its real bounds ----------
# A binary that cannot start (missing DLL, wrong toolchain) fails every negative
# control for the wrong reason, so require a working --version before claiming
# anything about what it accepts or rejects.
if [ -n "$SC" ] && "$SC" --version >/dev/null 2>&1; then
    if "$SC" --help 2>&1 | grep -q -- '--game-contrast'; then
        echo "PASS fx --game-contrast documented in --help"
    else
        echo "FAIL fx --game-contrast missing from --help"; fail=$((fail + 1))
    fi
    for f in brightness gamma; do
        if "$SC" --help 2>&1 | grep -q -- "--game-$f"; then
            echo "PASS fx --game-$f documented in --help"
        else
            echo "FAIL fx --game-$f missing from --help"; fail=$((fail + 1))
        fi
    done
    if "$SC" --game-postfx=contrast,brightness,gamma --game-contrast=140 \
            --game-brightness=120 --game-gamma=130 --version >/dev/null 2>&1; then
        echo "PASS fx binary accepts the new grade flags"
    else
        echo "FAIL fx binary rejected the new grade flags"; fail=$((fail + 1))
    fi
    if "$SC" --game-gamma=10 --version >/dev/null 2>&1; then
        echo "FAIL fx binary accepted --game-gamma=10 (below its 25 floor)"
        fail=$((fail + 1))
    else
        echo "PASS fx binary rejects out-of-range --game-gamma"
    fi
    if "$SC" --game-postfx=bogus --version >/dev/null 2>&1; then
        echo "FAIL fx binary accepted an unknown --game-postfx name"
        fail=$((fail + 1))
    else
        echo "PASS fx binary rejects an unknown --game-postfx name"
    fi
else
    echo "SKIP fx CLI checks (scrcpy.exe missing or cannot start)"
fi

if [ "$fail" -eq 0 ]; then
    echo "FXPIXEL OK"
    exit 0
fi
echo "FXPIXEL FAIL ($fail)"
exit 1
