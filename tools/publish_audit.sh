#!/usr/bin/env bash
#
# tools/publish_audit.sh — does this tree deserve to be published?
#
# `.gitignore` alone is not a publish boundary: it is absent from this working copy by
# the owner's choice, a fresh clone would not carry per-machine rules, and next to the
# sources there are 2.5 GB of measurement logs, the nested scrcpy clone and the 126 MB
# release archive. So the publishable set is declared in tools/publish_manifest.txt and
# this script fails when the tracked reality drifts from it. It is a gate section, not
# advice, and every check has a control that has to make it fail.
#
#   bash tools/publish_audit.sh            # audit this repository
#   bash tools/publish_audit.sh --controls # prove each check still bites
#
# Exit: 0 clean, 1 findings, 2 a control stopped working.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/tools/publish_manifest.txt"
PATTERNS="$ROOT/out/publish/forbidden_patterns.txt"
GENERIC="$ROOT/tools/publish_generic_patterns.txt"
ISSUES=0

ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; ISSUES=$((ISSUES + 1)); }
note() { printf 'NOTE %s\n' "$*"; }

# scan_tree INDEX_FILE ROOT MANIFEST_FILE — audits one tree and prints its findings.
scan_tree() {
    local indexfile="$1" root="$2" manifest="$3"
    ISSUES=0
    local index want have extra gone leak biggest bigb bigf pats hits f missing req s contract broken stale

    if [ ! -f "$indexfile" ]; then
        bad "cannot read the tracked-file list ($indexfile)"
        return 1
    fi
    index=$(grep -v '^[[:space:]]*$' "$indexfile")

    # 1 ---------------------------------------------------------- the publish set
    if [ ! -f "$manifest" ]; then
        bad "no publish manifest: nothing declares what may leave this machine"
    else
        want=$(printf '%s\n' "$index" | LC_ALL=C sort)
        have=$(grep -v '^#' "$manifest" | grep -v '^[[:space:]]*$' | LC_ALL=C sort)
        if [ "$want" = "$have" ]; then
            ok "the git index matches tools/publish_manifest.txt ($(printf '%s\n' "$have" | grep -c .) files)"
        else
            extra=$(LC_ALL=C comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
            gone=$(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
            [ -n "$extra" ] && bad "tracked but unlisted, would ship unreviewed: $(printf '%s' "$extra" | tr '\n' ' ')"
            [ -n "$gone" ] && bad "listed but not tracked, stale manifest: $(printf '%s' "$gone" | tr '\n' ' ')"
        fi
    fi

    # 2 ------------------------------------------------------- local-only artifacts
    leak=$(printf '%s\n' "$index" | grep -E '^(dist|out|workspace)/|^launcher/(bin|obj)/|^tools/(platform-tools|stock)/|(^|/)__pycache__/|\.log$|\.zip$' || true)
    if [ -z "$leak" ]; then
        ok "no build output, archive, log or nested clone is tracked"
    else
        bad "local-only paths are tracked: $(printf '%s' "$leak" | tr '\n' ' ')"
    fi

    # 3 ------------------------------------------------------------------ sizes
    biggest=$(printf '%s\n' "$index" | while read -r f; do
        [ -f "$root/$f" ] && printf '%s %s\n' "$(stat -c%s "$root/$f" 2>/dev/null || echo 0)" "$f"
    done | sort -rn | head -1)
    bigb=${biggest%% *}
    if [ -z "$biggest" ] || [ -z "$bigb" ]; then
        note "no files resolved under $root"
    elif [ "$bigb" -gt 52428800 ]; then
        bad "${biggest#* } is $bigb bytes — over the 50 MB budget for a source repository"
    else
        ok "largest tracked file is ${biggest#* } at $bigb bytes (< 50 MB)"
    fi

    # 4 ----------------------------------------------- identifiers and machine paths
    if [ -f "$PATTERNS" ]; then
        note "device-identifier patterns loaded from out/publish/ (a fresh clone checks machine paths only)"
    else
        note "out/publish/forbidden_patterns.txt absent: checking machine paths only"
    fi
    # Literal matching, never regex: an escaped backslash inside an ERE degrades to
    # "C:UsersAdministrator" and the check then passes everything while still printing OK.
    patfile=$(mktemp)
    # Machine-path patterns come from the audit's own tree: a fixture root being
    # checked has no tools/ directory, and a list that silently resolves to nothing
    # is how this check once passed a tree full of hardcoded paths.
    for pf in "$root/tools/publish_generic_patterns.txt" "$GENERIC" "$PATTERNS"; do
        [ -f "$pf" ] || continue
        grep -v '^#' "$pf" | grep -v '^[[:space:]]*$' >> "$patfile"
    done
    sort -u "$patfile" -o "$patfile"
    npat=$(grep -c . "$patfile" 2>/dev/null || echo 0)
    if [ "$npat" -eq 0 ]; then
        bad "no forbidden patterns available: the PII check has nothing to look for"
    else
        hits=""
        while read -r f; do
            [ -f "$root/$f" ] || continue
            case "$f" in
                # The prohibition lists necessarily contain the literals they forbid;
                # scanning them would report the instrument instead of the artifact.
                tools/publish_audit.sh|tools/publish_generic_patterns.txt) continue ;;
            esac
            grep -qFf "$patfile" -- "$root/$f" 2>/dev/null && hits="$hits $f"
        done <<< "$index"
        if [ -z "$hits" ]; then
            ok "no device serial or machine-specific path survives in the tracked files ($npat patterns checked)"
        else
            bad "PII or machine literals still present in:$hits"
        fi
    fi
    rm -f "$patfile"

    # 5 ------------------------------------------------- licence and provenance files
    req="LICENSE NOTICE THIRD-PARTY.md PROVENANCE.md README_GAMING.md CHANGELOG.md .gitignore tools/publish_manifest.txt"
    missing=""
    for f in $req; do
        [ -s "$root/$f" ] || missing="$missing $f"
    done
    if [ -z "$missing" ]; then
        ok "licence, notice, third-party and provenance documents are present and non-empty"
    else
        bad "required documents missing or empty:$missing"
    fi
    if grep -qi 'Apache License' "$root/LICENSE" 2>/dev/null; then
        ok "LICENSE is the Apache-2.0 text inherited with the scrcpy fork"
    else
        bad "LICENSE does not read like the Apache-2.0 text scrcpy is under"
    fi

    # 6 -------------------------------------------- the harnesses the gate invokes
    contract=$(grep -hoE 'tools/[A-Za-z0-9_]+\.(sh|ps1)' "$root/tools/verify_all.sh" "$root/tools/package_selftest.sh" 2>/dev/null | sort -u)
    if [ -z "$contract" ]; then
        bad "cannot derive the contract list: verify_all.sh or package_selftest.sh is absent"
    else
        broken=""
        for s in $contract; do
            [ -f "$root/$s" ] || broken="$broken $s"
        done
        if [ -z "$broken" ]; then
            ok "all $(printf '%s\n' "$contract" | grep -c .) scripts the gate invokes exist at their literal path"
        else
            bad "the gate invokes scripts that are not in the tree:$broken"
        fi
    fi

    # 7 --------------------------------------------- docs that cite moved locations
    stale=$(grep -rn --include='*.md' 'PHASE1_AUDIT\.md' "$root" 2>/dev/null \
            | grep -v 'doc/gaming/PHASE1_AUDIT\.md' | grep -v '/out/' | grep -v '/dist/' || true)
    if [ -z "$stale" ]; then
        ok "no document points at the pre-move location of PHASE1_AUDIT.md"
    else
        bad "stale reference to PHASE1_AUDIT.md: $(printf '%s' "$stale" | head -1)"
    fi

    return 0
}

# ========================================================================== modes
if [ "${1:-}" = "--controls" ]; then
    echo "=== publish audit controls (every control must produce a FAIL) ==="
    ctlfail=0
    tmp=$(mktemp -d)

    # control 1: a tree that leaks local-only paths and archives
    mkdir -p "$tmp/leak"
    printf 'launcher/App.xaml\nout/leak.log\ntools/scrcpy-stock.zip\nworkspace/scrcpy/app/src/gaming.c\n' > "$tmp/leak.index"
    printf 'launcher/App.xaml\n' > "$tmp/leak.manifest"
    n=$(AUDIT=1 bash "$0" --scan "$tmp/leak.index" "$tmp/leak" "$tmp/leak.manifest" | grep -c '^FAIL')
    if [ "$n" -ge 3 ]; then ok "[control leak] $n findings on a leaking tree"
    else bad "[control leak] only $n findings: the leak check is asleep"; ctlfail=1; fi

    # control 2: a file over the size budget
    mkdir -p "$tmp/big"
    printf 'huge.bin\n' > "$tmp/big.index"
    printf 'huge.bin\n' > "$tmp/big.manifest"
    dd if=/dev/zero of="$tmp/big/huge.bin" bs=1M count=51 seek=0 conv=sparse status=none
    n=$(bash "$0" --scan "$tmp/big.index" "$tmp/big" "$tmp/big.manifest" | grep -c 'over the 50 MB budget')
    if [ "$n" -ge 1 ]; then ok "[control big] the size budget bites"
    else bad "[control big] a 51 MB tracked file passed"; ctlfail=1; fi

    # control 3: required documents absent
    mkdir -p "$tmp/docs"
    printf 'README_GAMING.md\n' > "$tmp/docs.index"
    printf 'README_GAMING.md\n' > "$tmp/docs.manifest"
    n=$(bash "$0" --scan "$tmp/docs.index" "$tmp/docs" "$tmp/docs.manifest" | grep -c '^FAIL')
    if [ "$n" -ge 2 ]; then ok "[control missing] $n findings without the licence set"
    else bad "[control missing] absent LICENSE/NOTICE went unnoticed"; ctlfail=1; fi

    # control 4: a surviving literal — machine path always, device identifier when the
    # local key file is present. The path case is the one that once passed silently,
    # because a backslash in an ERE turns the pattern into something that matches nothing.
    mkdir -p "$tmp/pii"
    printf 'report.md\n' > "$tmp/pii.index"
    printf 'report.md\n' > "$tmp/pii.manifest"
    printf 'built on C:\\Users\\Administrator\\Desktop on 2026-10-19\n' > "$tmp/pii/report.md"
    n=$(bash "$0" --scan "$tmp/pii.index" "$tmp/pii" "$tmp/pii.manifest" | grep -c 'PII or machine literals')
    if [ "$n" -ge 1 ]; then ok "[control path] a hardcoded machine path is caught"
    else bad "[control path] the literal scan missed a C:\\Users path (regex rot?)"; ctlfail=1; fi
    if [ -f "$PATTERNS" ]; then
        first=$(grep -v '^#' "$PATTERNS" | grep -v '^[[:space:]]*$' | head -1)
        printf 'the device %s was measured on 2026-10-19\n' "$first" > "$tmp/pii/report.md"
        n=$(bash "$0" --scan "$tmp/pii.index" "$tmp/pii" "$tmp/pii.manifest" | grep -c 'PII or machine literals')
        if [ "$n" -ge 1 ]; then ok "[control pii] a surviving device identifier is caught"
        else bad "[control pii] the PII scan did not catch a serial"; ctlfail=1; fi
    else
        note "[control pii] skipped: no out/publish/forbidden_patterns.txt on this machine"
    fi

    # control 5: a manifest that drifts from the index
    mkdir -p "$tmp/drift"
    printf 'a.txt\nb.txt\n' > "$tmp/drift.index"
    printf 'a.txt\n' > "$tmp/drift.manifest"
    n=$(bash "$0" --scan "$tmp/drift.index" "$tmp/drift" "$tmp/drift.manifest" | grep -c 'unlisted\|stale manifest')
    if [ "$n" -ge 1 ]; then ok "[control manifest] index/manifest drift is caught"
    else bad "[control manifest] drift passed silently"; ctlfail=1; fi

    rm -rf "$tmp"
    if [ "$ctlfail" -ne 0 ]; then echo "PUBLISH CONTROLS FAIL"; exit 2; fi
    echo "PUBLISH CONTROLS OK"
    exit 0
fi

if [ "${1:-}" = "--scan" ]; then
    scan_tree "$2" "$3" "$4"
    if [ "$ISSUES" -gt 0 ]; then echo "PUBLISH FAIL issues=$ISSUES"; exit 1; fi
    echo "PUBLISH OK"; exit 0
fi

echo "=== publish audit ==="
IDX=$(mktemp)
(cd "$ROOT" && git ls-files) > "$IDX"
scan_tree "$IDX" "$ROOT" "$MANIFEST"
rm -f "$IDX"
if [ "$ISSUES" -gt 0 ]; then
    echo "PUBLISH FAIL issues=$ISSUES"
    exit 1
fi
echo "PUBLISH OK files=$(grep -c . "$MANIFEST" 2>/dev/null || echo '?')"
exit 0
