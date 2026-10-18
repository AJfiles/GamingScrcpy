#!/usr/bin/env bash
# Verify the deliverable the way the user receives it: the ZIP, extracted, with no
# build tree anywhere near it.
#
# The gate runs against the build tree; the build tree is not what ships, and it is
# the one layout that hides the bug class that already bit this project twice -- a
# harness that resolves its binary from workspace/scrcpy/build-usb/ passes at home
# and dies in the package. So every harness the README or the report claims is
# re-run here, from the extraction, and a few are checked for the opposite: the
# fixtures that must fail have to fail there too, or the green means nothing.
#
#   bash tools/package_selftest.sh                       # dist zip, out/pkg_selftest
#   bash tools/package_selftest.sh <zip> <extract-dir>
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="${1:-$ROOT/dist/GamingScrcpy-win64-fork.zip}"
DEST="${2:-$ROOT/out/pkg_selftest}"

[ -f "$ZIP" ] || { echo "MISSING archive: $ZIP"; exit 1; }

bytes=$(stat -c %s "$ZIP")
echo "archive $ZIP = $bytes bytes"

rm -rf "$DEST" || exit 1
mkdir -p "$DEST" || exit 1
pwsh() { powershell -NoProfile -ExecutionPolicy Bypass -Command "$*"; }
pwsh "Expand-Archive -LiteralPath '$(cygpath -w "$ZIP")' -DestinationPath '$(cygpath -w "$DEST")' -Force" \
    || { echo "EXTRACT FAIL"; exit 1; }

cd "$DEST" || exit 1
files=$(find . -type f | wc -l)
dirs=$(find . -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "extracted: $files files under $dirs top-level directories"
[ "$files" -gt 0 ] || { echo "EXTRACT produced no files"; exit 1; }

EXE="./launcher/GamingScrcpyLauncher.exe"
[ -f "$EXE" ] || { echo "MISSING $EXE in the package"; exit 1; }

fails=0
run() {
    local label="$1"; shift
    echo "=== $label ==="
    "$@"
    local rc=$?
    echo "rc=$rc"
    [ "$rc" -eq 0 ] || { echo "NOT OK: $label"; fails=$((fails + 1)); }
}
run_must_fail() {
    local label="$1"; shift
    echo "=== $label (must FAIL) ==="
    "$@"
    local rc=$?
    echo "rc=$rc"
    [ "$rc" -ne 0 ] || { echo "NOT OK: $label passed but had to fail"; fails=$((fails + 1)); }
}

run "overlay (latency A/B from the package)"  bash tools/overlay_test.sh
run "fx pixel assertions"                     bash tools/fx_pixel_test.sh
run "theme audit"                             bash tools/theme_audit.sh
run_must_fail "theme audit, broken palette"   bash tools/theme_audit.sh --app-xaml tools/fixtures/theme_bad_app.xaml
run "recorder integrity"                      bash tools/recorder_integrity_test.sh 30 320x180
run "launcher UI tree"                        powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_uiauto.ps1
run "tab screenshot"                          powershell -NoProfile -ExecutionPolicy Bypass -File tools/launcher_tab_shot.ps1 -Tab 0
run "auto-rescan probe"                       powershell -NoProfile -ExecutionPolicy Bypass -File tools/autoscan_probe.ps1
run "profiles valid"                          "$EXE" --validate-profiles
run "shortcut table valid"                    "$EXE" --validate-shortcuts
run_must_fail "shortcut duplicate fixture"    "$EXE" --validate-shortcuts "--shortcuts-file=tools/fixtures/shortcuts_duplicate.json"

echo
if [ "$fails" -eq 0 ]; then
    echo "PKGSELFTEST OK ($files files, $dirs dirs)"
else
    echo "PKGSELFTEST FAIL issues=$fails"
    exit 1
fi
