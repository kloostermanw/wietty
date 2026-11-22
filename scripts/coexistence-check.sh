#!/usr/bin/env bash
#
# coexistence-check.sh
#
# Proves that libghostty (the surface) and libghostty-vt (the terminal state the
# core keeps) can be live in one process: a real surface in a real window and a
# GhosttyVtTerminal are fed the same few megabytes of terminal output, and the
# visible grid of one is compared against the other after every segment, with
# the address sanitizer on.
#
# The normal suite cannot do this. It runs against FakeSurfaceHost with no
# window and no Metal device, on purpose, so the test this runs
# (GhosttyVtCoexistenceTests) is skipped unless WIETTY_COEXISTENCE_CHECK=1 is
# set. Run this after changing the pin of either library, and before relying on
# a new one.
#
# It opens a Wietty window for a few seconds, so it needs a logged in desktop
# session, and Wietty itself must not be running: the test host is the app, and
# a second instance contends for its ports.
#
# The sanitizer build replaces the normal one in derived data, so this compiles
# everything again and takes a few minutes, and so does the next ordinary build.
# A derived data directory of its own would avoid that and is deliberately not
# used: it resolves every package from scratch, and that fails whenever a
# dependency's tag has moved since Package.resolved recorded it.
#
# Usage: scripts/coexistence-check.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if pgrep -x Wietty >/dev/null; then
  echo "Wietty is running. Quit it first: the check launches the app as its test host." >&2
  exit 1
fi

# The project file is generated and not tracked, so it can be stale.
xcodegen generate

LOG="$(mktemp -t wietty-coexistence)"
echo "Building with the address sanitizer and running the check. Full log: ${LOG}"

# TEST_RUNNER_ is how xcodebuild passes a variable through to the test host.
set +e
TEST_RUNNER_WIETTY_COEXISTENCE_CHECK=1 xcodebuild \
  -scheme Wietty \
  -destination 'platform=macOS' \
  -enableAddressSanitizer YES \
  -only-testing:WiettyTests/GhosttyVtCoexistenceTests \
  test >"${LOG}" 2>&1
STATUS=$?
set -e

# What the test printed, any disagreement it recorded, and anything the
# sanitizer had to say.
grep -E '^COEXISTENCE|^(✔|✘) |recorded an issue|disagree|lines differ|surface: |vt:  |AddressSanitizer|\*\* TEST' "${LOG}" \
  | grep -v 'surface: surface closed' || true

if [ "${STATUS}" -ne 0 ]; then
  echo "The coexistence check FAILED (xcodebuild exited ${STATUS}). See ${LOG}" >&2
  exit "${STATUS}"
fi
if ! grep -q '^COEXISTENCE: .*address sanitizer ON' "${LOG}"; then
  echo "The test did not report a sanitized run, so this proves nothing. See ${LOG}" >&2
  exit 1
fi
echo "The coexistence check passed."
