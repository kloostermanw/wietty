#!/usr/bin/env bash
#
# remote-surface-check.sh
#
# Measures what showing a terminal of another Mac in a libghostty surface costs
# and does (phase 3 step 5 of issue #84): a snapshot fed through the bridge and
# the helper to a surface its child left dirty (R1), backpressure through the
# package's WebSocket client against a real RemoteServer on 127.0.0.1 (R2), the
# cost of a show and of 100 shows and hides (R3), large snapshots through the
# helper's pump (R4), the ends that stop the helper (R7) and fast hides and shows
# (R8). Every line of a result starts with STEP5.
#
# The normal suite cannot do this. It needs a window, a Metal device and minutes,
# so the test this runs (RemoteSurfaceMeasurementTests) is skipped unless
# WIETTY_REMOTE_SURFACE_CHECK=1 is set.
#
# It opens a Wietty window for several minutes, so it needs a logged in desktop
# session with a display awake, and Wietty itself must not be running: the test
# host is the app.
#
# Usage: scripts/remote-surface-check.sh [test name, e.g. r1ASnapshotOnADirtySurface]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if pgrep -x Wietty >/dev/null; then
  echo "Wietty is running. Quit it first: the check launches the app as its test host." >&2
  exit 1
fi

# The project file is generated and not tracked, so it can be stale.
xcodegen generate

ONLY="WiettyTests/RemoteSurfaceMeasurementTests"
if [ "$#" -gt 0 ]; then ONLY="${ONLY}/$1()"; fi

LOG="$(mktemp -t wietty-remote-surface)"
echo "Building and running the remote surface check. Full log: ${LOG}"

# TEST_RUNNER_ is how xcodebuild passes a variable through to the test host.
set +e
TEST_RUNNER_WIETTY_REMOTE_SURFACE_CHECK=1 xcodebuild \
  -scheme Wietty \
  -destination 'platform=macOS' \
  -only-testing:"${ONLY}" \
  test >"${LOG}" 2>&1
STATUS=$?
set -e

grep -E '^STEP5|^(✔|✘) |recorded an issue|\*\* TEST' "${LOG}" || true
if grep -q 'CVDisplayLinkCreateWithCGDisplays' "${LOG}"; then
  echo "A surface could not create its display link: the display is asleep. Wake it and run again." >&2
fi
exit "${STATUS}"
