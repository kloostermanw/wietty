#!/usr/bin/env bash
#
# reload-surface-check.sh
#
# Checks that a libghostty surface can be created on a GhosttySurfaceHost after
# reloadConfig() on that same host, which is what the app does when a colour is
# changed in Settings and a terminal is opened next. It runs reload then create
# 25 times in each of four ways (a fresh host each time, one host, one host with
# the overlay changed before every reload, and one host with a surface kept alive
# through every reload) and prints one RELOAD line per way.
#
# The normal suite cannot do this. It needs a window and a Metal device, so the
# test this runs (ReloadThenCreateSurfaceTests) is skipped unless
# WIETTY_RELOAD_SURFACE_CHECK=1 is set. The overlay it changes is the test
# host's sandboxed ghostty.cfg, never the user's own.
#
# A display must be awake: libghostty creates a surface's display link from the
# active displays, and with none it fails the surface with error.OutOfMemory.
#
# With --asan it builds with the address sanitizer. That build replaces the normal
# one in derived data, so it compiles everything again, and so does the next
# ordinary build.
#
# It opens a Wietty window for some seconds, so it needs a logged in desktop
# session, and Wietty itself must not be running: the test host is the app.
#
# Usage: scripts/reload-surface-check.sh [--asan]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SANITIZER=()
if [ "${1:-}" = "--asan" ]; then
  SANITIZER=(-enableAddressSanitizer YES)
fi

if pgrep -x Wietty >/dev/null; then
  echo "Wietty is running. Quit it first: the check launches the app as its test host." >&2
  exit 1
fi

# The project file is generated and not tracked, so it can be stale.
xcodegen generate

LOG="$(mktemp -t wietty-reload-surface)"
# Keep the log only when the check failed: it is what the error message points at.
KEEP_LOG=0
trap '[ "${KEEP_LOG}" = 1 ] || rm -f "${LOG}"' EXIT
echo "Building and running the reload surface check. Full log: ${LOG} (removed when the check passes)"

# TEST_RUNNER_ is how xcodebuild passes a variable through to the test host.
set +e
TEST_RUNNER_WIETTY_RELOAD_SURFACE_CHECK=1 xcodebuild \
  -scheme Wietty \
  -destination 'platform=macOS' \
  ${SANITIZER[@]+"${SANITIZER[@]}"} \
  -only-testing:WiettyTests/ReloadThenCreateSurfaceTests \
  test >"${LOG}" 2>&1
STATUS=$?
set -e

grep -E '^RELOAD|^(✔|✘) |recorded an issue|error initializing surface|CVDisplayLink|AddressSanitizer|\*\* TEST' "${LOG}" || true

if [ "${STATUS}" -ne 0 ]; then
  KEEP_LOG=1
  echo "The reload surface check FAILED (xcodebuild exited ${STATUS}). See ${LOG}" >&2
  exit "${STATUS}"
fi
if ! grep -q '^RELOAD-RESULT: 0 failures' "${LOG}"; then
  KEEP_LOG=1
  echo "The test did not report its result, so this proves nothing. See ${LOG}" >&2
  exit 1
fi
echo "The reload surface check passed."
