#!/usr/bin/env bash
# v4 §5.2/§5.4: the two gates the directive asks for, as one runnable check.
#
#   §23 reduced motion  - every animation duration must come from one resource
#                         key, and the code must zero that key when Windows says
#                         "no animations" (SystemParameters.ClientAreaAnimation).
#                         A hard-coded Duration="0:0:0.2" cannot be turned off,
#                         so it is a finding even though it is under the budget.
#   §24 visual polish   - no animation over 250 ms, no FontSize over 16 outside
#                         the title styles, no shadow with blur < 8 or opacity
#                         > 0.5.
#
# Both are static checks on purpose: they must run in the gate on a machine with
# no display, and a rendered-pixel assertion would be a flake factory. The
# positive controls at the end prove each rule can actually fail -- a check that
# cannot fail is not a check.
#
# Exit: 0 all green, 1 a finding, 2 the launcher sources are not where they
# should be (SKIP-safe for a machine without the checkout).
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/launcher
pass=0; fail=0
# The directive asks for two gate sections out of this one harness, and a gate
# relay cannot split a colored block by its header. So each rule tallies into its
# own section and the two verdicts are printed as machine-readable lines.
sec=23; p23=0; f23=0; p24=0; f24=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1))
        if [ "$sec" -eq 23 ]; then p23=$((p23+1)); else p24=$((p24+1)); fi; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1))
        if [ "$sec" -eq 23 ]; then f23=$((f23+1)); else f24=$((f24+1)); fi; }
note(){ printf '  \033[33mnote\033[0m  %s\n' "$1"; }
head_() { printf '\n\033[36m== %s\033[0m\n' "$1"; }

[ -d "$src" ] || { echo "SKIP  no launcher sources at $src"; exit 2; }
xaml=$(find "$src" -maxdepth 2 -name '*.xaml' -not -path '*/obj/*' -not -path '*/bin/*')
[ -n "$xaml" ] || { echo "SKIP  no XAML to inspect"; exit 2; }

# ---- §23 reduced motion ------------------------------------------------------
sec=23
head_ "23. animations obey the Windows reduced-motion setting"
keys=$(grep -ohE 'x:Key="(Anim[A-Za-z]*)"' $xaml 2>/dev/null \
    | sed 's/.*x:Key="//; s/"//' | sort -u)
if [ -z "$keys" ]; then
    bad "no animation duration keys in the theme: nothing can honour reduced motion"
else
    ok "duration keys defined: $(echo "$keys" | tr '\n' ' ')"
fi
hard=$(grep -nE 'Duration="0:0:' $xaml 2>/dev/null \
    | grep -v 'DynamicResource\|StaticResource' | wc -l | tr -d ' ')
if [ "$hard" -eq 0 ]; then
    ok "every Duration in the XAML resolves through a resource key"
else
    bad "$hard hard-coded Duration values; they survive no setting"
    grep -nE 'Duration="0:0:' $xaml | grep -v 'DynamicResource\|StaticResource' | head -3 \
        | sed 's/^/          /'
fi
if grep -rq "SystemParameters.ClientAreaAnimation" "$src" --include=*.cs; then
    ok "the code reads SystemParameters.ClientAreaAnimation"
else
    bad "nothing reads SystemParameters.ClientAreaAnimation, so the keys are never zeroed"
fi
# The filter panel is a second UI in another process, in SDL, so the same switch
# has to be asked there too. Only checked when the fork sources are present: the
# launcher ships on machines that never built the C tree.
fork=$root/workspace/scrcpy/app/src/overlay.c
if [ -f "$fork" ]; then
    if grep -q "SPI_GETCLIENTAREAANIMATION" "$fork"; then
        ok "the mirror panel asks SPI_GETCLIENTAREAANIMATION too"
    else
        bad "the mirror panel animates without asking Windows"
    fi
else
    note "no fork sources at $fork: the panel's reduced-motion switch unchecked"
fi

# ---- §24 polish regression ---------------------------------------------------
sec=24
head_ "24. no animation over 250 ms, no oversized type, no broken shadow"
# durations are in seconds inside the resource keys, so read the values
over=0
while read -r key val; do
    ms=$(awk -v v="$val" 'BEGIN{
        # accepts 0:0:0.2 and 0:0:0.250 and 00:00:00.200
        n = split(v, p, ":"); s = p[n] + 0
        printf "%d", s * 1000 }')
    if [ "$ms" -gt 250 ]; then
        printf '          %s = %s (%s ms)\n' "$key" "$val" "$ms"
        over=$((over+1))
    fi
done < <(grep -hoE 'x:Key="Anim[A-Za-z]*"[^>]*>[^<]*' $xaml 2>/dev/null \
         | sed -E 's/x:Key="([^"]*)".*>(.*)/\1 \2/')
if [ "$over" -eq 0 ]; then
    ok "no animation duration exceeds 250 ms"
else
    bad "$over animation(s) exceed 250 ms"
fi

# Both spellings count: the theme sets most of its sizes through a Setter, so a
# rule that only read the FontSize=".." attribute would let a 28 px Setter through.
big=$(grep -nE 'FontSize="(1[7-9]|[2-9][0-9])"|Property="FontSize"[[:space:]]+Value="(1[7-9]|[2-9][0-9])"' $xaml 2>/dev/null \
    | grep -viE 'Title|Header|Brand|Hero')
if [ -z "$big" ]; then
    ok "no FontSize above 16 outside the title styles"
else
    printf '%s\n' "$big" | sed 's/^/          /'
    bad "$(printf '%s\n' "$big" | wc -l | tr -d ' ') oversized FontSize value(s)"
fi

broken=$(grep -nE 'DropShadowEffect' $xaml 2>/dev/null \
    | grep -vE 'BlurRadius="([89]|[1-9][0-9]+)"[^>]*ShadowDepth="0"[^>]*Opacity="0?\.[0-4][0-9]*"')
if [ -z "$broken" ]; then
    ok "every card shadow is soft (blur >= 8, depth 0, opacity <= 0.5)"
else
    printf '%s\n' "$broken" | sed 's/^/          /' | head -3
    bad "$(printf '%s\n' "$broken" | wc -l | tr -d ' ') shadow(s) outside the soft range"
fi

# ---- positive controls -------------------------------------------------------
# Each rule is run against a fixture that breaks exactly that rule. Without this
# block a typo in a pattern would report green forever. Each control is tagged
# with the section whose rule it tests, both so the tallies land in the right
# verdict and so the gate relay -- which reads one section at a time -- cannot
# lose the line that proves the check can fail.
head_ "controls: each rule must be able to fail"
fx=$(mktemp -d)
trap 'rm -rf "$fx"' EXIT
cat > "$fx/Slow.xaml" <<'EOF'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Duration x:Key="AnimSlow">0:0:0.5</Duration>
</ResourceDictionary>
EOF
cat > "$fx/Noisy.xaml" <<'EOF'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <TextBlock FontSize="28" Text="oversized"/>
  <Style TargetType="TextBlock"><Setter Property="FontSize" Value="22"/></Style>
  <Border Effect="{DropShadowEffect BlurRadius=2 ShadowDepth=8 Opacity=0.9}"/>
  <DoubleAnimation Duration="0:0:0.4" Storyboard.TargetProperty="Opacity"/>
</Grid>
EOF
check_over() { # file -> prints the number of durations over 250 ms
    grep -hoE 'x:Key="Anim[A-Za-z]*"[^>]*>[^<]*' "$1" \
        | sed -E 's/x:Key="([^"]*)".*>(.*)/\1 \2/' \
        | awk '{ n = split($2, p, ":"); if (p[n] * 1000 > 250) c++ } END { print c + 0 }'
}
sec=24
if [ "$(check_over "$fx/Slow.xaml")" -eq 1 ]; then
    ok "[control §24] the 500 ms fixture is caught by the duration rule"
else
    bad "[control §24] the 500 ms fixture slipped through: the duration rule cannot fail"
fi
if grep -qE 'FontSize="(1[7-9]|[2-9][0-9])"' "$fx/Noisy.xaml"; then
    ok "[control §24] the FontSize=28 fixture is caught"
else
    bad "[control §24] the FontSize rule cannot fail"
fi
if grep -qE 'Property="FontSize"[[:space:]]+Value="(1[7-9]|[2-9][0-9])"' "$fx/Noisy.xaml"; then
    ok "[control §24] the Setter FontSize=22 fixture is caught"
else
    bad "[control §24] the Setter form of an oversized font slips through"
fi
if grep -nE 'DropShadowEffect' "$fx/Noisy.xaml" \
   | grep -qvE 'BlurRadius="([89]|[1-9][0-9]+)"[^>]*ShadowDepth="0"[^>]*Opacity="0?\.[0-4][0-9]*"'; then
    ok "[control §24] the blur=2/opacity=0.9 fixture is caught"
else
    bad "[control §24] the shadow rule cannot fail"
fi
sec=23
if grep -qE 'Duration="0:0:' "$fx/Noisy.xaml" && \
   ! grep -qE 'DynamicResource|StaticResource' "$fx/Noisy.xaml"; then
    ok "[control §23] the hard-coded Duration fixture is caught"
else
    bad "[control §23] the reduced-motion rule cannot fail"
fi

printf '\nRESULT pass=%s fail=%s\n' "$pass" "$fail"
printf 'RESULT23 pass=%s fail=%s\n' "$p23" "$f23"
printf 'RESULT24 pass=%s fail=%s\n' "$p24" "$f24"
[ "$fail" -eq 0 ] || exit 1
