#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="cmux.xcodeproj"
SCHEME="cmux-unit"
CONFIGURATION="${CMUX_TEST_CONFIGURATION:-Debug}"
DESTINATION="${CMUX_TEST_DESTINATION:-platform=macOS}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

# Bracket the run with the leaked-agent reaper. A test that builds its child
# environment from ProcessInfo.processInfo.environment inherits the real
# CMUX_*_WRAPPER_SHIM and can launch the user's real, authenticated agent, which
# is then orphaned to launchd and spins CPU forever. The wrapper guards in
# Resources/bin/cmux-{codex,claude}-wrapper block the common path; this is the
# backstop for anything that escapes. Set CMUX_SKIP_AGENT_REAP=1 to opt out.
REAPER="$(dirname "$0")/reap-leaked-agents.sh"
REAP_ENABLED=0
if [ "${CMUX_SKIP_AGENT_REAP:-0}" != "1" ] && [ -x "$REAPER" ]; then
  REAP_ENABLED=1
  "$REAPER" --snapshot || true
fi

set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  "$@"
XCODEBUILD_STATUS=$?
set -e

if [ "$REAP_ENABLED" = "1" ]; then
  "$REAPER" --reap || true
fi

exit "$XCODEBUILD_STATUS"
