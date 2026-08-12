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

# The bundle has to be signed, ad hoc is enough, and shipping one that is not is a
# silent failure rather than a loud one: macOS refuses to ask for notification
# permission for a bundle it does not accept, so bells and OSC 9 notifications
# stop working while everything else looks fine. That is what
# CODE_SIGNING_ALLOWED: NO shipped for months. See docs/notifications.md.
echo "==> Checking the signature"
codesign --verify --deep --strict "$APP_PATH" \
  || { echo "refusing to package an unsigned app: check CODE_SIGN settings in project.yml" >&2; exit 1; }

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
