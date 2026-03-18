#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
STEP_BLOCK="$(
  sed -n '/^      - name: Run compatibility unit test slice$/,/^      - name:/p' "$WORKFLOW_FILE" | sed '$d'
)"

require_pattern() {
  local pattern="$1"
  local message="$2"
  if ! grep -q -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: $message"
    exit 1
  fi
}

reject_pattern() {
  local pattern="$1"
  local message="$2"
  if grep -q -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: $message"
    exit 1
  fi
}

require_pattern "compat_test_filters:" "ci-macos-compat.yml must define explicit compatibility test filters"
require_pattern "cmuxTests/AppDelegateLaunchServicesRegistrationTests" "macOS 15 compat filters are missing"
require_pattern "cmuxTests/ZshShellIntegrationHandoffTests" "macOS 26 compat filters are missing"

if [ -z "$STEP_BLOCK" ]; then
  echo "FAIL: compat workflow is missing the compatibility test-slice step"
  exit 1
fi

if ! grep -q -- "while IFS= read -r filter; do" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat step must still load test filters into an array"
  exit 1
fi

if ! grep -q -- "-scheme cmux-unit" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat step must run the cmux-unit scheme"
  exit 1
fi

if ! grep -q -- "test 2>&1" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat step must execute unit tests"
  exit 1
fi

if grep -q -- "scripts/unit_test_shard_args.py" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat workflow must not rely on shard-based test selection inside the compat step"
  exit 1
fi

echo "PASS: macOS compat workflow keeps an explicit compatibility unit test slice"
