#!/usr/bin/env bash
#
# imposed-grid-check.sh
#
# Measures whether a grid can be imposed on a libghostty surface by giving its
# view exactly the size that belongs to the grid: (cols * cell width + padding)
# divided by the backing scale, and the same for rows. For seven grids it sets
# that size on a real surface in a real window, then reads the grid back from
# the surface and from `stty size` in its child, and prints one line per grid
# and variant starting with IMPOSED.
#
# It runs four configurations in one go: the attached display's backing scale
# and the other one (1 or 2, simulated by a window that reports it, since the
# display's settings are never touched), each with the default window padding
# and with window-padding-x = 13, window-padding-y = 7. The padding goes into
# the test host's sandboxed ghostty.cfg, never the user's own files.
#
# The normal suite cannot do this. It needs a window and a Metal device, so the
# test this runs (ImposedGridMeasurementTests) is skipped unless
# WIETTY_IMPOSED_GRID_CHECK=1 is set.
#
# It opens a Wietty window for some seconds, so it needs a logged in desktop
# session, and Wietty itself must not be running: the test host is the app, and
# a second instance contends for its ports.
#
# Usage: scripts/imposed-grid-check.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if pgrep -x Wietty >/dev/null; then
  echo "Wietty is running. Quit it first: the check launches the app as its test host." >&2
  exit 1
fi

# The project file is generated and not tracked, so it can be stale.
xcodegen generate

LOG="$(mktemp -t wietty-imposed-grid)"
# Keep the log only when the check failed: it is what the error message points at.
KEEP_LOG=0
trap '[ "${KEEP_LOG}" = 1 ] || rm -f "${LOG}"' EXIT
echo "Building and running the imposed grid check. Full log: ${LOG} (removed when the check passes)"

# TEST_RUNNER_ is how xcodebuild passes a variable through to the test host.
set +e
TEST_RUNNER_WIETTY_IMPOSED_GRID_CHECK=1 xcodebuild \
  -scheme Wietty \
  -destination 'platform=macOS' \
  -only-testing:WiettyTests/ImposedGridMeasurementTests \
  test >"${LOG}" 2>&1
STATUS=$?
set -e

grep -E '^IMPOSED|^(✔|✘) |recorded an issue|\*\* TEST' "${LOG}" || true

if [ "${STATUS}" -ne 0 ]; then
  KEEP_LOG=1
  echo "The imposed grid check FAILED (xcodebuild exited ${STATUS}). See ${LOG}" >&2
  exit "${STATUS}"
fi
if [ "$(grep -c '^IMPOSED ' "${LOG}")" -ne 112 ]; then
  KEEP_LOG=1
  echo "The run did not print 112 IMPOSED lines, so it measured less than it should. See ${LOG}" >&2
  exit 1
fi
echo "The imposed grid check passed: every grid was exact with both paddings."
