#!/usr/bin/env bash
# Reap real agent processes leaked by the test suite.
#
# Why this exists
# ---------------
# Tests that build a child environment from ProcessInfo.processInfo.environment
# inherit CMUX_CODEX_WRAPPER_SHIM / CMUX_CLAUDE_WRAPPER_SHIM. The resume command
# cmux generates (AgentResumeArgv.swift) prefers that shim over a PATH lookup, so
# the fake agent stub a test installs on PATH is bypassed and the user's REAL,
# authenticated agent is launched -- historically `codex resume <fake-id> --yolo`.
# The resulting TUI is orphaned to launchd when its parent shell exits and spins
# its event loop forever, burning CPU until it is killed by hand.
#
# Resources/bin/cmux-{codex,claude}-wrapper now refuse to exec under XCTest, which
# closes the common path. This script is the backstop: it catches anything that
# still escapes (a test invoking a binary directly, an agent bypassing the shim,
# or a wrapper that has not been rebuilt into the bundle yet).
#
# Usage
# -----
#   scripts/reap-leaked-agents.sh --snapshot   # before running the suite
#   scripts/reap-leaked-agents.sh --list       # dry run: what would be reaped
#   scripts/reap-leaked-agents.sh --reap       # after the suite: kill leaks
#
#   --state <path>   override the snapshot file
#   --force          reap new agent processes even if not yet orphaned
#
# Safety contract
# ---------------
# A process is only reaped when BOTH hold:
#   1. its PID was not present at --snapshot time, AND
#   2. it is now parented to launchd (PPID 1), i.e. genuinely orphaned
#      (relaxed by --force, which drops requirement 2 only).
# Anything running before the snapshot is never touched, so a codex or claude
# session you started yourself survives regardless of how long the suite runs.

set -uo pipefail

STATE_FILE="${TMPDIR:-/tmp}/cmux-agent-reaper-snapshot.txt"
MODE=""
FORCE=0

# Matches the real agent binaries plus anything routed through a cmux shim.
# Deliberately anchored on argv patterns that only a launched agent produces, so
# editors, language servers and greps for these words are not matched.
AGENT_PATTERN='codex-aarch64-apple-darwin|Codex\.app/Contents/Resources/codex|cmux-cli-shims/[^ ]*/(codex|claude)|(^|/)(codex|claude|opencode|grok)( |$)|(^|/)pi( |$)'

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Print "pid ppid command" for every live agent-looking process, excluding this
# script, its pipeline, and any ps/rg helpers it spawns.
list_agent_processes() {
    ps -axo pid=,ppid=,command= 2>/dev/null \
        | grep -Ev "reap-leaked-agents|[[:space:]]grep[[:space:]]|[[:space:]]rg[[:space:]]" \
        | grep -E "$AGENT_PATTERN" \
        | awk '{ $1=$1; print }'
}

case "${1:-}" in
    --snapshot) MODE="snapshot" ;;
    --reap)     MODE="reap" ;;
    --list)     MODE="list" ;;
    -h|--help)  usage 0 ;;
    *)          echo "error: expected --snapshot, --list or --reap" >&2; usage 2 ;;
esac
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state) STATE_FILE="${2:?--state needs a path}"; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "error: unknown argument: $1" >&2; usage 2 ;;
    esac
done

if [[ "$MODE" == "snapshot" ]]; then
    list_agent_processes | awk '{ print $1 }' | sort -u > "$STATE_FILE"
    printf 'snapshot: %s pre-existing agent process(es) recorded in %s\n' \
        "$(wc -l < "$STATE_FILE" | tr -d ' ')" "$STATE_FILE"
    exit 0
fi

if [[ ! -f "$STATE_FILE" ]]; then
    echo "error: no snapshot at $STATE_FILE -- run --snapshot before the suite" >&2
    exit 1
fi

leaked=()
while read -r pid ppid command; do
    [[ -z "${pid:-}" ]] && continue
    # Pre-existing at snapshot time: never ours to kill.
    grep -qx "$pid" "$STATE_FILE" && continue
    # New, but still attached to a live parent: let that parent own its child.
    if [[ "$FORCE" != "1" && "$ppid" != "1" ]]; then
        continue
    fi
    leaked+=("$pid|$ppid|$command")
done < <(list_agent_processes)

if [[ ${#leaked[@]} -eq 0 ]]; then
    echo "clean: no leaked agent processes"
    exit 0
fi

printf 'found %s leaked agent process(es):\n' "${#leaked[@]}"
for entry in "${leaked[@]}"; do
    printf '  pid=%s ppid=%s %s\n' "${entry%%|*}" \
        "$(cut -d'|' -f2 <<<"$entry")" "$(cut -d'|' -f3- <<<"$entry")"
done

if [[ "$MODE" == "list" ]]; then
    echo "(dry run -- re-run with --reap to kill these)"
    exit 0
fi

for entry in "${leaked[@]}"; do
    pid="${entry%%|*}"
    kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
still_alive=0
for entry in "${leaked[@]}"; do
    pid="${entry%%|*}"
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        still_alive=$((still_alive + 1))
    fi
done

printf 'reaped %s process(es)' "${#leaked[@]}"
[[ "$still_alive" -gt 0 ]] && printf ' (%s needed SIGKILL)' "$still_alive"
printf '\n'
echo "NOTE: a leak means a test escaped the wrapper guard -- fix the test, do not just reap."
exit 0
