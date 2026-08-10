#!/usr/bin/env bash
#
# build-and-start.sh
#
# Stops Wietty if it is running, builds the Debug app from the current
# checkout, then launches it. Handy for testing local changes.
#
# Usage: scripts/build-and-start.sh [configuration]
#   configuration defaults to Debug (pass Release to build the release config).

set -euo pipefail

SCHEME="Wietty"
APP_NAME="Wietty"
CONFIGURATION="${1:-Debug}"

# Run from the repository root regardless of where the script is invoked.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 1. Stop the app if it is currently running.
if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "Stopping running ${APP_NAME}..."
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  # Wait up to ~5s for a graceful quit, then force kill if still alive.
  for _ in $(seq 1 10); do
    pgrep -x "${APP_NAME}" >/dev/null || break
    sleep 0.5
  done
  if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "Force killing ${APP_NAME}..."
    killall "${APP_NAME}" 2>/dev/null || true
  fi
fi

# 2. Build.
echo "Building ${SCHEME} (${CONFIGURATION})..."
xcodebuild -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS' \
  build

# 3. Resolve the built .app path from the build settings (avoids hardcoding the
# DerivedData hash) and launch it.
BUILT_PRODUCTS_DIR="$(
  xcodebuild -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
)"

APP_PATH="${BUILT_PRODUCTS_DIR}/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
  echo "error: built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Starting ${APP_PATH}..."
open "${APP_PATH}"
