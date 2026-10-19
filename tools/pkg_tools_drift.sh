#!/usr/bin/env bash
# The package ships its own copies of the harnesses (dist/GamingScrcpy/tools),
# because that is what the user unzips and runs. A copy can go stale, and one
# did: the packaged UI Automation probe kept a check the repo copy had already
# replaced, so the build tree was green while the deliverable failed its own
# older test.
#
# The same class has two more members, both seen in v4: a `dotnet publish` whose
# -o path was mangled by bash landed in a garbage sibling directory and left the
# shipped exe untouched, and a docs edit that never made it back into the archive.
# So this checks the three ways a package stops being the current thing:
# packaged harnesses identical, the shipped exe not older than its sources, and
# the archive not older than the tree it was built from.
#
#   bash tools/pkg_tools_drift.sh
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/tools"
dst="$root/dist/GamingScrcpy/tools"
dist="$root/dist/GamingScrcpy"

[ -d "$dst" ] || { echo "SKIP no packaged tools at ${dst#$root/}"; exit 2; }

rc=0
drift=""
missing=""
for f in "$src"/*.sh "$src"/*.ps1; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if [ ! -f "$dst/$b" ]; then
        missing="$missing $b"
    elif ! cmp -s "$f" "$dst/$b"; then
        drift="$drift $b"
    fi
done
if [ -n "$drift" ]; then
    echo "FAIL packaged harnesses differ from tools/:$drift"
    rc=1
fi
if [ -n "$missing" ]; then
    echo "FAIL tools/ has harnesses the package does not ship:$missing"
    rc=1
fi
if [ -z "$drift$missing" ]; then
    n=$(find "$dst" -maxdepth 1 -type f | wc -l | tr -d ' ')
    echo "OK $n packaged files, every one byte-identical to tools/"
fi

# The theme inputs the packaged audit reads when there is no build tree
# (tools/theme/) are copies of launcher sources, and a copy of those went stale
# the same way the harness copies did: the packaged theme audit then asserted the
# three depth brushes against a snapshot from before they existed.
theme="$dst/theme"
if [ ! -d "$theme" ]; then
    echo "note no shipped theme inputs at ${theme#$root/}: the packaged audit has nothing to read"
else
    tbad=""
    for f in "$theme"/*; do
        b=$(basename "$f")
        [ -f "$root/launcher/$b" ] || { tbad="$tbad $b(no source)"; continue; }
        cmp -s "$root/launcher/$b" "$f" || tbad="$tbad $b"
    done
    if [ -n "$tbad" ]; then
        echo "FAIL the shipped theme inputs differ from launcher/:$tbad"
        rc=1
    else
        echo "OK shipped theme inputs ($(cd "$theme" && ls | tr '\n' ' ')) are the launcher's own"
    fi
fi

# The shipped launcher must be at least as new as everything it is built from.
# A publish that silently did not happen looks exactly like a green build.
exe="$dist/launcher/GamingScrcpyLauncher.exe"
if [ ! -f "$exe" ]; then
    echo "note no packaged launcher exe at ${exe#$root/} to compare against"
else
    stale=$(find "$root/launcher" -maxdepth 1 \( -name '*.cs' -o -name '*.xaml' \
            -o -name '*.csproj' \) -newer "$exe" 2>/dev/null | head -1)
    [ -f "$root/launcher/Assets/app.ico" ] && stale=${stale:-$(find "$root/launcher/Assets/app.ico" \
        -newer "$exe" 2>/dev/null | head -1)}
    if [ -n "$stale" ]; then
        echo "FAIL ${exe#$root/} is older than ${stale#$root/}: the package carries a launcher built before that change"
        rc=1
    else
        echo "OK packaged launcher is not older than any launcher source or the app icon"
    fi
fi

# And the archive must have been rebuilt after the tree changed. The three
# markdown files at the root are excluded on purpose: the report inside an
# archive can never quote the size of the archive it is in (it would have to be
# written after the compression it describes), so letting them drive this check
# would make the gate unwinnable rather than honest.
zip="$root/dist/GamingScrcpy-win64-fork.zip"
if [ ! -f "$zip" ]; then
    echo "note no archive at ${zip#$root/} yet (build it before the deliverable claim)"
else
    newer=$(find "$dist" -type f ! -path "$dist/*.md" -newer "$zip" 2>/dev/null | head -1)
    if [ -n "$newer" ]; then
        echo "FAIL the archive is older than ${newer#$root/}: dist/ changed after the last repack"
        rc=1
    else
        echo "OK archive is not older than any binary, tool or theme file in dist/GamingScrcpy"
    fi
fi

if [ "$rc" -ne 0 ]; then echo "PKGDRIFT FAIL"; exit 1; fi
echo "PKGDRIFT OK"
