#!/usr/bin/env bash
#
# stream-baseline.sh
#
# Measures typing delay and throughput on the terminal byte path, from where
# wietty-pty stands: the echo of one keystroke on a quiet terminal, the same
# while the main thread is busy for 50 ms out of every 60, and how fast 100 MB
# of output reaches the far end, once as one endless line and once as ordinary
# 80 character lines. Each prints one line starting with BASELINE.
#
# The normal suite cannot do this. The measurement takes tens of seconds and
# means nothing beside a parallel run, so the test this runs
# (StreamBaselineTests) is skipped unless WIETTY_STREAM_BASELINE=1 is set. Run
# this before and after changing the route a terminal's bytes take, and compare.
#
# It opens no window, but Wietty itself must not be running: the test host is
# the app, and a second instance contends for its ports.
#
# Usage: scripts/stream-baseline.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if pgrep -x Wietty >/dev/null; then
  echo "Wietty is running. Quit it first: the baseline launches the app as its test host." >&2
  exit 1
fi

# The project file is generated and not tracked, so it can be stale.
xcodegen generate

LOG="$(mktemp -t wietty-stream-baseline)"
echo "Building and running the stream baseline. Full log: ${LOG}"

# TEST_RUNNER_ is how xcodebuild passes a variable through to the test host.
set +e
TEST_RUNNER_WIETTY_STREAM_BASELINE=1 xcodebuild \
  -scheme Wietty \
  -destination 'platform=macOS' \
  -only-testing:WiettyTests/StreamBaselineTests \
  test >"${LOG}" 2>&1
STATUS=$?
set -e

grep -E '^BASELINE|^(✔|✘) |recorded an issue|\*\* TEST' "${LOG}" || true

if [ "${STATUS}" -ne 0 ]; then
  echo "The stream baseline FAILED (xcodebuild exited ${STATUS}). See ${LOG}" >&2
  exit "${STATUS}"
fi
if [ "$(grep -c '^BASELINE' "${LOG}")" -ne 4 ]; then
  echo "The run did not print four BASELINE lines, so it measured nothing. See ${LOG}" >&2
  exit 1
fi
echo "The stream baseline finished."
