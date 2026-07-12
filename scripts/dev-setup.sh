#!/usr/bin/env bash
# Turnkey dev-build entrypoint: build + launch the macOS dev app auto-signed-in,
# with no manual sign-in. Wraps the P1 macOS auto-sign-in path.
#
# Everything here is DEBUG-only and targets the TAGGED app/socket/bundle id, so
# it never touches the user's stable cmux instance.
#
# Flow:
#   1. Load dev sign-in creds (dogfood account wins).
#   2. Enable the iOS pairing host on the tagged build (opt-in, default OFF):
#        defaults write com.cmuxterm.app.debug.<tag-id> mobile.iOSPairingHost.enabled -bool true
#      Written BEFORE the macOS launch so a single build binds the NWListener on
#      first launch. NOTE: the first bind per bundle id triggers a one-time macOS
#      "Local Network" permission prompt; click Allow. (The pairing host serves
#      any cmux iOS app on the network; this repo does not build one.)
#   3. Build + launch the macOS dev app via reload.sh --tag <t> --launch. It
#      auto-signs-in from ~/.secrets/cmuxterm-dev.env (DebugDogfoodCredentialResolver).
#
# Usage:
#   scripts/dev-setup.sh --tag grid                 # build + launch, pairing host on
#   scripts/dev-setup.sh --tag grid --no-pair       # skip enabling the pairing host
#
# Flags:
#   --tag <t>           required; tags the macOS dev build.
#   --profile <name>    apply an environment preset after the app is up. Replays
#                       scripts/dev-profiles/<name>.json against the tagged debug
#                       socket (composer, notif, browser, groups, multi-mac, ...).
#                       Accepts a comma-list to compose (e.g. composer,browser).
#                       Run `scripts/dev-profiles/replay-cli.mjs --list` for names.
#   --no-pair           skip enabling the pairing host.

set -euo pipefail

TAG=""
PROFILE=""
NO_PAIR=0

usage() { sed -n '2,30p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --no-pair) NO_PAIR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "error: --tag is required" >&2; usage >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_REPLAY="$SCRIPT_DIR/dev-profiles/replay-cli.mjs"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"

# --- profiles: validate up front (P3) ---------------------------------------
# Fail fast on an unknown profile name BEFORE any heavy build/launch work, so a
# typo doesn't cost a full build. --dry-run validates parse + resolution without
# touching a socket; it lists the available profiles on an unknown name.
if [[ -n "$PROFILE" ]]; then
  if ! node "$PROFILE_REPLAY" --dry-run --profile "$PROFILE" >/dev/null; then
    echo "error: invalid --profile '$PROFILE'." >&2
    echo "available profiles:" >&2
    node "$PROFILE_REPLAY" --list | sed 's/^/  /' >&2
    exit 2
  fi
fi

# --- credentials: validate only, do NOT export into this process -------------
# The macOS app reads dogfood creds from disk (DebugDogfoodCredentialResolver).
# This script must NOT export CMUX_UITEST_STACK_PASSWORD: reload.sh launches the
# long-lived GUI process inheriting this environment (it only scrubs a denylist,
# and the Stack vars are not on it), which would leak the password to every child
# terminal/CLI the app spawns. Validate in a subshell to surface a clear early
# error, but keep the password out of dev-setup.sh's environment.
# shellcheck source=scripts/lib/dev-secrets.sh
if ! ( source "$SCRIPT_DIR/lib/dev-secrets.sh"; cmux_dev_secrets_load ); then
  exit 2
fi

# --- tag identity (delegated to scripts/lib/mobile-attach.sh) ----------------
# slug -> socket path + DerivedData; tag-id -> bundle id. The shared lib owns the
# exact derivation so it stays in sync with reload.sh / cmux-debug-cli.sh.
dev_setup__sanitize_path() { cmux_attach__slug "$1"; }
dev_setup__sanitize_bundle() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

TAG_SLUG="$(dev_setup__sanitize_path "$TAG")"
TAG_ID="$(dev_setup__sanitize_bundle "$TAG")"
BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"

# --- enable the iOS pairing host (must precede the macOS launch) -------------
enable_pairing_host() {
  echo "==> enabling iOS pairing host on $BUNDLE_ID (opt-in, default OFF)"
  echo "    (first bind per bundle id triggers a one-time macOS Local Network prompt; click Allow)"
  # The host listener is opt-in. createAttachTicket returns empty routes unless
  # the NWListener is bound. MobileHostService.start() reads this default at app
  # launch (applicationDidFinishLaunching), so it must be written BEFORE the
  # macOS launch below. The tagged bundle id is targeted, never the stable app.
  cmux_attach_enable_pairing_host "$TAG"
}

# --- macOS build + launch (P1 auto-sign-in) ---------------------------------
# Writing the pairing default first means a single reload.sh build binds the
# listener on its first launch (no double build).
build_and_launch_mac() {
  echo "==> building + launching macOS dev app (tag: $TAG)"
  # reload.sh --launch builds the tagged Debug app and opens it. The macOS app
  # auto-signs-in from ~/.secrets/cmuxterm-dev.env via DebugDogfoodCredentialResolver.
  "$REPO_ROOT/scripts/reload.sh" --tag "$TAG" --launch
}

# --- apply environment profile(s) (P3) --------------------------------------
# Profiles provision a realistic test environment against the TAGGED Mac socket
# via scripts/cmux-debug-cli.sh. The replay engine spawns the debug CLI, which
# refuses without CMUX_TAG and never touches the stable app.
apply_profile() {
  echo "==> applying profile(s) '$PROFILE' against $SOCKET_PATH"
  # The Mac app needs its socket bound before the debug CLI can connect. Poll
  # the socket file (the real readiness signal), bounded so a never-launching
  # app fails clearly instead of hanging.
  local _attempt
  for _attempt in $(seq 1 40); do
    [[ -S "$SOCKET_PATH" ]] && break
    sleep 0.25
  done
  if [[ ! -S "$SOCKET_PATH" ]]; then
    echo "error: tagged socket $SOCKET_PATH never appeared; is the Mac dev app for tag '$TAG' running?" >&2
    exit 1
  fi
  node "$PROFILE_REPLAY" --tag "$TAG" --profile "$PROFILE" --cwd "$REPO_ROOT"
}

# --- orchestrate ------------------------------------------------------------
# Enable the pairing host BEFORE the macOS launch so a single build binds the
# listener on first launch (the default is read in applicationDidFinishLaunching).
if [[ "$NO_PAIR" -eq 0 ]]; then
  enable_pairing_host
fi

build_and_launch_mac

if [[ -n "$PROFILE" ]]; then
  apply_profile
fi

echo "==> dev-setup complete (tag: $TAG)"
