#!/usr/bin/env bash
# Directive v4 §3.3, as a runnable check.
#
# Three things, all of them measured against the real scrcpy.exe rather than
# argued about:
#   1. at least 19 builtin profiles ship (the set is 20 since the latency and
#      fluidity presets were added),
#   2. every one of them is accepted by the packaged binary, through the
#      launcher's own --validate-profiles self test, which builds the command
#      line the same way a session does and hands scrcpy --version, so it parses
#      and leaves without ever reaching a device,
#   3. every one carries a non-empty description in Spanish AND in English,
# plus the display-name half of the same directive section: the Spanish label is
# what a Spanish user reads and what the mirror window is titled with, while the
# stored identity that keys the JSON file stays the one it has always had. And
# finally that what the code declares is what the store hands back: the launcher
# launches the JSON file, not the C# object, so a parameter the serializer drops
# would be a profile that quietly stops meaning what its name says.
#
# The invariant this protects (the sizes in the profile names are a client-side
# maximum, never a change to the device) is gate section 13 of verify_all.sh;
# this script checks the three items above and nothing else, so it can run on a
# machine with no build tree and no phone attached.
#
# Usage: bash tools/profiles_check.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="/c/msys64/ucrt64/bin:$PATH"

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "OK    $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $1"; }
note() { echo "note  $1"; }

# Both layouts, like the other harnesses: the extracted package first, because
# that is what a user runs, then the build tree. A candidate is only usable if a
# scrcpy.exe can be found from it, otherwise the self test reports "not found"
# and every profile would be judged without a judge.
launcher=""
for c in "$root/dist/GamingScrcpy/launcher/GamingScrcpyLauncher.exe" \
         "$root/launcher/GamingScrcpyLauncher.exe" \
         "$root/launcher/bin/Release/net8.0-windows/win-x64/GamingScrcpyLauncher.exe"; do
    [ -f "$c" ] || continue
    d=$(dirname "$c")
    if [ -f "$d/../scrcpy/scrcpy.exe" ] || [ -f "$d/scrcpy.exe" ]; then
        launcher=$c
        break
    fi
done
if [ -z "$launcher" ]; then
    bad "no GamingScrcpyLauncher.exe with a scrcpy.exe next to it (publish the launcher into dist/GamingScrcpy/launcher, or copy scrcpy.exe beside the build-tree exe)"
    echo "PROFILES CHECK FAIL issues=$fail"
    exit 1
fi
note "launcher: $launcher"

out=$("$launcher" --validate-profiles 2>&1)
rc=$?
lines=$(printf '%s\n' "$out" | grep -c . || true)
if [ "${lines:-0}" -lt 3 ]; then
    bad "the self test produced $lines line(s): nothing to judge, reporting no pass"
    echo "PROFILES CHECK FAIL issues=$fail"
    exit 1
fi

# ---- the count line the self test prints about its own builtin set ----
builtin_line=$(printf '%s\n' "$out" | grep '^BUILTINS ' | head -1)
if [ -z "$builtin_line" ]; then
    # the check would otherwise pass on an exe built before the line existed
    bad "no BUILTINS line in the self-test output: this launcher exe does not report the builtin set"
    echo "PROFILES CHECK FAIL issues=$fail"
    exit 1
fi
field() { printf '%s\n' "$builtin_line" | sed -n "s/.*$1=\([0-9][0-9]*\).*/\1/p"; }
n=$(field n)
no_es=$(field desc_es_missing)
no_en=$(field desc_en_missing)
no_name=$(field name_es_missing)
for v in n no_es no_en no_name; do
    if [ -z "${!v}" ]; then
        bad "the BUILTINS line is incomplete ('$builtin_line'): cannot judge $v"
        echo "PROFILES CHECK FAIL issues=$fail"
        exit 1
    fi
done

if [ "$n" -ge 19 ]; then
    ok "$n builtin profiles shipped (needs 19)"
else
    bad "only $n builtin profiles shipped (needs 19)"
fi

# ---- every builtin valid against the real binary ----
# counted from the PASS lines the self test printed for the builtins, so a green
# exit code cannot hide a profile that never ran.
checked=$(printf '%s\n' "$out" | grep -c '^PASS builtin ' || true)
if [ "${checked:-0}" -eq "$n" ]; then
    ok "$checked/$n builtin profiles accepted by the real scrcpy.exe"
else
    bad "only $checked of $n builtin profiles reported PASS"
    printf '%s\n' "$out" | grep '^FAIL builtin ' | sed 's/^/        /'
fi
if printf '%s\n' "$out" | grep -q 'scrcpy.exe not found'; then
    bad "the self test could not find scrcpy.exe, so nothing was validated"
fi
if printf '%s\n' "$out" | grep -q '^FAIL '; then
    bad "the self test reported a FAIL line: $(printf '%s\n' "$out" | grep -c '^FAIL ')"
    printf '%s\n' "$out" | grep '^FAIL ' | head -5 | sed 's/^/        /'
fi
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'ALL PROFILES VALID'; then
    ok "--validate-profiles exited 0 with ALL PROFILES VALID"
else
    bad "--validate-profiles exited $rc without the ALL PROFILES VALID verdict"
fi

# ---- the two description languages ----
if [ "$no_es" -eq 0 ]; then
    ok "every builtin carries a non-empty Spanish description"
else
    bad "$no_es builtin profile(s) have no Spanish description"
fi
if [ "$no_en" -eq 0 ]; then
    ok "every builtin carries a non-empty English description"
else
    bad "$no_en builtin profile(s) have no English description"
fi
if [ "$no_name" -eq 0 ]; then
    ok "every builtin carries a Spanish display name"
else
    note "$no_name builtin profile(s) show only their internal name in Spanish"
fi

# ---- the Spanish label is what the user reads and what the window is titled ----
spanish_line=$(printf '%s\n' "$out" | grep '^SPANISH ' | head -1)
if [ -z "$spanish_line" ]; then
    bad "no SPANISH line in the self-test output: cannot prove the display name reaches the window title"
else
    stuck=$(printf '%s\n' "$spanish_line" | sed -n 's/.*display_equals_identity=\([0-9][0-9]*\).*/\1/p')
    title=$(printf '%s\n' "$spanish_line" | sed -n 's/.*window_title_not_display_name=\([0-9][0-9]*\).*/\1/p')
    example=$(printf '%s\n' "$spanish_line" | sed -n 's/.*example=//p')
    if [ -z "$stuck" ] || [ -z "$title" ]; then
        bad "the SPANISH line is incomplete ('$spanish_line')"
    elif [ "$stuck" -ne 0 ]; then
        bad "$stuck builtin profile(s) still display their internal identity in Spanish"
    elif [ "$title" -ne 0 ]; then
        bad "$title profile(s) title the mirror window with the identity, not the label"
    else
        ok "Spanish labels shown, identity kept (e.g. $example)"
    fi
fi

# ---- what the code declares must be what the store gives back ----
roundtrip_line=$(printf '%s\n' "$out" | grep '^ROUNDTRIP ' | head -1)
if [ -z "$roundtrip_line" ]; then
    bad "no ROUNDTRIP line in the self-test output: cannot prove the profile file keeps its parameters"
else
    lost=$(printf '%s\n' "$roundtrip_line" | sed -n 's/.*parameters_lost=\([0-9][0-9]*\).*/\1/p')
    if [ -z "$lost" ]; then
        bad "the ROUNDTRIP line is incomplete ('$roundtrip_line')"
    elif [ "$lost" -eq 0 ]; then
        ok "every builtin survives the JSON store round trip"
    else
        bad "$lost builtin profile(s) lose a parameter through the JSON store"
    fi
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "PROFILES CHECK FAIL issues=$fail"; exit 1; }
echo "PROFILES CHECK OK builtin=$n valid=$checked desc_es=$((n - no_es)) desc_en=$((n - no_en))"
