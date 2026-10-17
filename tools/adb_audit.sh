#!/usr/bin/env bash
# One line per command this project runs against the real device, so the owner
# of the tablet can review exactly what was touched during a test session.
# Sourced by the probes or called directly:
#   bash tools/adb_audit.sh "adb -s $serial shell getprop ro.product.model"
set -u

log=${AUDIT_LOG:-}
if [ -z "$log" ]; then
    here=$(cd "$(dirname "$0")" && pwd)
    log="$here/../out/dev/adb_audit.log"
fi
mkdir -p "$(dirname "$log")" 2>/dev/null || exit 0
if [ ! -f "$log" ]; then
    {
        echo "# adb / scrcpy audit log"
        echo "# every device command run by the harnesses, one per line (UTC)."
        echo "# read-only by project rule: the blacklist scan in gate section 14 enforces it."
    } >> "$log"
fi
printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$log"
