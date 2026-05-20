#!/usr/bin/env bash
# memory_leak2.md Phase 0 helper. Print total IOSurface bytes for a PID,
# parsed from `vmmap --summary`. Region count alone is too brittle to use as
# the primary memory-release assertion in the hibernation tests; this gives
# the byte total the plan calls for.
#
# Usage:
#   ./scripts/iosurface-bytes.sh <pid>
#
# Example:
#   ./scripts/iosurface-bytes.sh "$(pgrep -f 'cmux DEV' | head -1)"
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <pid>" >&2
    exit 64
fi

pid="$1"

if ! kill -0 "$pid" 2>/dev/null; then
    echo "pid $pid is not running" >&2
    exit 1
fi

# vmmap --summary emits one line like:
#   IOSurface                       1.7G    194
# We want the size token (1.7G) and the unit (G/M/K), multiplied out.
vmmap --summary "$pid" | awk '
    /^IOSurface[ \t]/ {
        val = $2
        n = val + 0
        unit = substr(val, length(n)+1, 1)
        mult = 1
        if (unit == "K") mult = 1024
        else if (unit == "M") mult = 1024 * 1024
        else if (unit == "G") mult = 1024 * 1024 * 1024
        printf "%d\n", n * mult
        found = 1
        exit
    }
    END {
        if (!found) {
            print "no IOSurface row in vmmap --summary output" > "/dev/stderr"
            exit 1
        }
    }
'
