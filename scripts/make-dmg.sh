#!/bin/bash
# Build a Release Wietty.app and package it into a drag-to-Applications .dmg.
# Usage: scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Wietty"
DERIVED="build-release"
DMG_OUT="$APP_NAME.dmg"

echo "==> Regenerating Xcode project (picks up bundled .py resources)"
xcodegen generate >/dev/null

echo "==> Building Release"
xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" build >/dev/null

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "build failed: $APP_PATH missing" >&2; exit 1; }

echo "==> Staging disk-image contents"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-target for the user

echo "==> Creating $DMG_OUT"
rm -f "$DMG_OUT"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_OUT" >/dev/null

echo "==> Done: $(pwd)/$DMG_OUT"
