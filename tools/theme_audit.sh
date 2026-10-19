#!/usr/bin/env bash
# v3 section 4.1 gate helper: the theme as data, checked rather than eyeballed.
#
# Five properties the directive calls mandatory, all decidable from the sources:
#   one accent only (every other colour is a surface, a foreground or a state),
#   corner radius inside 6-8 px everywhere,
#   no symbol glyphs in a visible string (punctuation such as ... stays allowed),
#   keyboard focus differentiated by shape and not only by colour,
#   every text pair the theme actually paints at WCAG AA (4.5:1).
#
# Usage: theme_audit.sh [--app-xaml FILE] [--loc FILE] [--xaml-glob GLOB]
# tools/fixtures/theme_bad_app.xaml must make it fail: a check that cannot fail
# is not a check.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/launcher/App.xaml"
LOC="${ROOT}/launcher/Loc.cs"
GLOB="${ROOT}/launcher/*.xaml"
while [ $# -gt 0 ]; do
    case "$1" in
        --app-xaml) APP="$2"; shift 2 ;;
        --loc) LOC="$2"; shift 2 ;;
        --xaml-glob) GLOB="$2"; shift 2 ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done
# An extracted package has no build tree: the launcher ships as an exe, so the
# theme inputs travel next to this script instead. Each input falls back on its
# own, because --app-xaml may legitimately point at a fixture while the radius
# census still reads the real XAML.
THEME_DIR="${ROOT}/tools/theme"
[ -f "$APP" ] || [ ! -f "${THEME_DIR}/App.xaml" ] || APP="${THEME_DIR}/App.xaml"
[ -f "$LOC" ] || [ ! -f "${THEME_DIR}/Loc.cs" ] || LOC="${THEME_DIR}/Loc.cs"
if ! compgen -G "$GLOB" > /dev/null && compgen -G "${THEME_DIR}/*.xaml" > /dev/null; then
    GLOB="${THEME_DIR}/*.xaml"
fi
if [ ! -f "$APP" ] || [ ! -f "$LOC" ]; then
    echo "FAIL neither $APP nor ${THEME_DIR}/ carries the theme sources"
    echo "THEME FAIL inputs=missing"; exit 1
fi
issues=0
bad() { echo "FAIL $1"; issues=$((issues + 1)); }
ok() { echo "OK $1"; }

# -- one accent ---------------------------------------------------------------
accents=$(grep -o 'x:Key="Accent[0-9A-Za-z]*"' "$APP" | sort -u | wc -l)
if [ "$accents" -eq 1 ]; then
    ok "exactly one brush named Accent* ($(grep -o 'x:Key="Accent[0-9A-Za-z]*"' "$APP" | head -1 | sed 's/.*Key="//; s/"//'))"
else
    bad "$accents brushes named Accent* (must be exactly one)"
fi
for k in $(grep -o 'x:Key="[A-Za-z0-9]*" Color=' "$APP" | sed 's/x:Key="//; s/" Color=//' \
           | grep -v '^Bg$\|^Panel$\|^Panel2$\|^Elevated$\|^Sunken$\|^Edge$\|^Line$\|^Fg$\|^FgDim$\|^Accent$\|^Good$\|^Warn$\|^Danger$\|^PrimaryBg$\|^RecordBg$\|^StopBg$\|^ComboHi$'); do
    bad "colour '$k' is neither a surface, a foreground, the accent nor a named state"
done

# The three depth surfaces v4 §5.1 asks for are named here, so the allowlist
# above is a role registry rather than a hole: a brush may only be new if it is
# one of these three, and then it has to be the colour the directive picked.
for pair in 'Elevated:#FF1E2130' 'Sunken:#FF0A0B0F' 'Edge:#FF2A2D3A'; do
    name=${pair%%:*}; hex=${pair##*:}
    if grep -q "x:Key=\"$name\" Color=\"$hex\"" "$APP"; then
        ok "$name is $hex, the depth surface v4 §5.1 names"
    else
        bad "$name is not declared as $hex in the theme"
    fi
done

# -- radius -------------------------------------------------------------------
r_out=$(grep -rho 'CornerRadius="[0-9]*"' $GLOB 2>/dev/null | grep -o '[0-9]*' \
        | awk '$1 < 6 || $1 > 8' | sort -u | tr '\n' ' ')
if [ -z "${r_out// /}" ]; then
    ok "every CornerRadius is inside 6-8 px ($(grep -rho 'CornerRadius="[0-9]*"' $GLOB | sort -u | tr '\n' ' '))"
else
    bad "corner radii outside 6-8 px: $r_out"
fi

# -- no symbol glyphs in visible strings --------------------------------------
# Geometric shapes, arrows, dingbats and astral-plane pictographs are icons and
# have to come from one set; here the set is empty, so none may appear. An
# ellipsis or a dash is punctuation and stays allowed.
sym=$(grep -o '\u21[9a-f][0-9a-f]\|\u2[56][0-9a-f][0-9a-f]\|\u27[0-9a-f][0-9a-f]\|\u2b[0-9a-f][0-9a-f]\|\ud8[0-9a-f][0-9a-f]' "$LOC" | sort -u | tr '\n' ' ')
if [ -z "${sym// /}" ]; then
    ok "no symbol glyphs in the localized strings"
else
    bad "symbol glyphs in visible strings: $sym"
fi

# -- focus is a shape, not only a colour --------------------------------------
if grep -q 'IsKeyboardFocused' "$APP"; then
    ok "the control templates carry a keyboard-focus trigger"
else
    bad "no IsKeyboardFocused trigger: focus would differ only by colour"
fi

# -- contrast -----------------------------------------------------------------
# the pairs the theme really paints (foreground, background, kind)
pairs='Fg:Bg:text Fg:Panel:text Fg:Panel2:text Fg:PrimaryBg:text Fg:RecordBg:text Fg:StopBg:text
       Fg:ComboHi:text FgDim:Bg:text FgDim:Panel:text FgDim:Panel2:text Accent:Bg:text
       Accent:Panel:text Accent:Panel2:text Good:Panel:text Warn:Panel:text'
mapfile -t colors < <(grep -o 'x:Key="[A-Za-z0-9]*" Color="#FF[0-9A-Fa-f]\{6\}"' "$APP" \
                      | sed 's/x:Key="//; s/" Color="#FF/ /; s/"$//')
ratio() {
    awk -v fg="$1" -v bg="$2" 'function lin(c){c=c/255; return c<=0.03928?c/12.92:((c+0.055)/1.055)^2.4}
        function lum(h,  r,g,b){r=strtonum("0x" substr(h,1,2));g=strtonum("0x" substr(h,3,2));b=strtonum("0x" substr(h,5,2))
            return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)}
        BEGIN{a=lum(fg);b=lum(bg); if(a<b){t=a;a=b;b=t}; printf "%.2f", (a+0.05)/(b+0.05)}'
}
hexof() { local n="$1"; printf '%s\n' "${colors[@]}" | awk -v k="$n" '$1==k{print $2}'; }
checked=0
for p in $pairs; do
    f=${p%%:*}; rest=${p#*:}; b=${rest%%:*}
    fh=$(hexof "$f"); bh=$(hexof "$b")
    if [ -z "$fh" ] || [ -z "$bh" ]; then bad "pair $f on $b: a colour is missing from the palette"; continue; fi
    r=$(ratio "$fh" "$bh")
    awk -v r="$r" 'BEGIN{exit !(r+0 >= 4.5)}' || { bad "contrast $f on $b = ${r}:1 (needs 4.5:1)"; continue; }
    checked=$((checked + 1))
done
if [ "$checked" -ge 12 ]; then
    ok "$checked text pairs at or above WCAG AA"
else
    bad "only $checked pairs could be evaluated (palette incomplete)"
fi

if [ "$issues" -gt 0 ]; then echo "THEME FAIL issues=$issues"; exit 1; fi
echo "THEME OK pairs=$checked"
