# tools/layout.sh — where the sources, the build tree and the package actually are.
#
# Sourced, not executed. This project has been built in three layouts and every one of
# them has hidden a bug that the others could not see:
#
#   dev     the app lives at the repository root and the scrcpy fork is a nested clone
#           at $ROOT/workspace/scrcpy (its build tree is $ROOT/workspace/scrcpy/build-usb)
#   fork    the scrcpy tree IS the repository root (published layout: app/ and tools/
#           and launcher/ side by side), so the build tree is $ROOT/build-usb
#   package the extracted ZIP: no sources and no build tree at all, the binaries sit
#           next to the harnesses under scrcpy/
#
# A harness that hardcodes one of them passes at home and dies elsewhere -- that is the
# defect class tools/package_selftest.sh exists to catch, and six harnesses used to
# resolve gamingdemo.exe from the build tree only. Resolve through this file instead of
# repeating a candidate list.
#
# Sets (and exports) when not already provided by the caller:
#   ROOT    repository or package root          (caller computes this from BASH_SOURCE)
#   SRC     scrcpy source tree, or empty        (has app/src/gaming.c when real)
#   BUILD   a build tree that exists, else the place one would be created
#   DIST    packaged folder, if present         (dist/GamingScrcpy or ../GamingScrcpy)
#   OUT     scratch/log directory for the harness
#   LAYOUT  dev | fork | package, for reporting and for §-style assertions
#   DEMO    gamingdemo.exe, first that exists (empty if none)
#   SC      scrcpy.exe, first that exists (empty if none)

[ -n "${ROOT:-}" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"

# The fork layout is detected by what only it has: sources at the repository root.
if [ -d "$ROOT/app/src" ]; then
    LAYOUT=fork
    SRC="$ROOT"
elif [ -d "$ROOT/workspace/scrcpy/app/src" ]; then
    LAYOUT=dev
    SRC="$ROOT/workspace/scrcpy"
else
    LAYOUT=package
    SRC=""
fi

if [ -d "$ROOT/dist/GamingScrcpy" ]; then
    DIST="$ROOT/dist/GamingScrcpy"
elif [ -d "$ROOT/../GamingScrcpy" ]; then
    DIST="$(cd "$ROOT/../GamingScrcpy" && pwd)"
elif [ -d "$ROOT/scrcpy" ]; then
    # inside an extracted archive the binaries are a sibling of tools/
    DIST="$ROOT"
else
    # Nothing packaged yet: fall back to the canonical place a build WOULD write to,
    # so a caller's "$DIST/launcher/x.exe" is a real path that reports missing rather
    # than an empty variable that silently becomes "/launcher/x.exe".
    DIST="$ROOT/dist/GamingScrcpy"
fi

[ -n "${OUT:-}" ] || OUT="$ROOT/out"

if [ -n "$SRC" ]; then
    if [ -d "$SRC/build-usb" ]; then BUILD="$SRC/build-usb"
    elif [ -d "$SRC/build-x" ]; then BUILD="$SRC/build-x"
    else BUILD="$SRC/build-usb"; fi
else
    BUILD=""
fi

# Candidate order is deliberate: a freshly built binary proves more about the sources
# than a packaged one, but a packaged layout has nothing else. The server asset is the
# reason a build-tree scrcpy.exe is not always usable -- see profile_sweep_device.sh.
DEMO=""
for c in "$BUILD/app/gamingdemo.exe" "$DIST/scrcpy/gamingdemo.exe" "$ROOT/scrcpy/gamingdemo.exe"; do
    [ -n "$c" ] && [ -f "$c" ] && { DEMO="$c"; break; }
done
SC=""
for c in "$BUILD/app/scrcpy.exe" "$DIST/scrcpy/scrcpy.exe" "$DIST/scrcpy.exe" "$ROOT/scrcpy/scrcpy.exe"; do
    [ -n "$c" ] && [ -f "$c" ] && { SC="$c"; break; }
done

export ROOT SRC BUILD DIST OUT LAYOUT DEMO SC

# How to report a missing binary: never print OK about an empty measurement.
layout_require() {   # layout_require <path> <what it is>
    if [ -z "${1:-}" ] || [ ! -e "$1" ]; then
        printf 'FAIL %s not found (layout=%s, SRC=%s, BUILD=%s, DIST=%s)\n' \
            "${2:-binary}" "$LAYOUT" "${SRC:-none}" "${BUILD:-none}" "${DIST:-none}"
        return 1
    fi
    return 0
}
