#!/bin/bash
# Build a Release Wietty.app and package it into a drag-to-Applications .dmg,
# signed with Developer ID and notarized, so Gatekeeper accepts it on any Mac.
#
# Usage: scripts/make-dmg.sh
#
# Needs, in the keychain of the Mac that runs it:
#   - the "Developer ID Application" certificate of the team in project.yml;
#   - notarization credentials stored under a profile name, once:
#       xcrun notarytool store-credentials wietty-notary --apple-id <id> --team-id <team>
#     The profile name can be changed with WIETTY_NOTARY_PROFILE.
#
# Without the certificate: WIETTY_ADHOC=1 scripts/make-dmg.sh builds the same image
# ad hoc signed and not notarized. It runs on the Mac that built it and Gatekeeper
# rejects it everywhere else. See docs/releasing.md.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Wietty"
DERIVED="build-release"
DMG_OUT="$APP_NAME.dmg"
NOTARY_PROFILE="${WIETTY_NOTARY_PROFILE:-wietty-notary}"
ADHOC="${WIETTY_ADHOC:-0}"

echo "==> Regenerating Xcode project (picks up bundled .py resources)"
xcodegen generate >/dev/null

# Asked before the build, which takes minutes, rather than after it.
if [ "$ADHOC" != 1 ]; then
  security find-identity -v -p codesigning | grep -q '"Developer ID Application: ' \
    || { echo "no Developer ID Application certificate in the keychain." >&2
         echo "Install it, or run WIETTY_ADHOC=1 $0 for an image that only this Mac accepts." >&2
         exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "no usable notarization credentials under the profile \"$NOTARY_PROFILE\"." >&2
         echo "Store them once: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team>" >&2
         exit 1; }
fi

APP_PATH="$DERIVED/Build/Products/Release/$APP_NAME.app"

# The bundle is removed first because an incremental build does not copy the
# wietty-pty helper into it again when only the helper's signature changed, which
# leaves a helper signed the old way inside a bundle signed the new way.
rm -rf "$APP_PATH"

echo "==> Building Release"
if [ "$ADHOC" = 1 ]; then
  xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= \
    ENABLE_HARDENED_RUNTIME=NO build >/dev/null
else
  xcodebuild -scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" build >/dev/null
fi

[ -d "$APP_PATH" ] || { echo "build failed: $APP_PATH missing" >&2; exit 1; }

# The bundle has to be signed, ad hoc is enough, and shipping one that is not is a
# silent failure rather than a loud one: macOS refuses to ask for notification
# permission for a bundle it does not accept, so bells and OSC 9 notifications
# stop working while everything else looks fine. That is what
# CODE_SIGNING_ALLOWED: NO shipped for months. See docs/notifications.md.
echo "==> Checking the signature"
codesign --verify --deep --strict "$APP_PATH" \
  || { echo "refusing to package an unsigned app: check CODE_SIGN settings in project.yml" >&2; exit 1; }

if [ "$ADHOC" != 1 ]; then
  # Notarization refuses a bundle in which any one binary is ad hoc signed or lacks
  # the secure timestamp, and says so only after the upload. Every signed item is
  # checked here first: the app, the helper, and each framework and library.
  TEAM="$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ -n "$TEAM" ] && [ "$TEAM" != "not set" ] \
    || { echo "the app is not signed with a team identity" >&2; exit 1; }
  while IFS= read -r item; do
    details="$(codesign -dvv "$item" 2>&1)"
    grep -q "^Authority=Developer ID Application: " <<<"$details" \
      && grep -q "^TeamIdentifier=$TEAM\$" <<<"$details" \
      && grep -q "^Timestamp=" <<<"$details" \
      || { echo "not signed with Developer ID of team $TEAM and a timestamp: $item" >&2; exit 1; }
  done < <(
    echo "$APP_PATH"
    find "$APP_PATH/Contents/MacOS" -type f -perm +111
    find "$APP_PATH/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null
  )
fi

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

if [ "$ADHOC" = 1 ]; then
  echo "==> Done, ad hoc signed and not notarized: $(pwd)/$DMG_OUT"
  exit 0
fi

echo "==> Signing the disk image"
codesign --sign "Developer ID Application" --timestamp "$DMG_OUT"

# Apple scans the image and everything in it. `--wait` blocks until the verdict,
# usually a few minutes. On a refusal the log names each binary and the reason.
echo "==> Notarizing (this waits for Apple)"
SUBMISSION="$(xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$SUBMISSION" | grep -E "^ *(id|status):" | tail -2
if ! grep -q "status: Accepted" <<<"$SUBMISSION"; then
  ID="$(sed -n 's/^ *id: //p' <<<"$SUBMISSION" | head -1)"
  echo "notarization was not accepted. The log:" >&2
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || echo "$SUBMISSION" >&2
  exit 1
fi

# The ticket travels with the image, so a Mac that is offline can check it too.
echo "==> Stapling the ticket"
xcrun stapler staple "$DMG_OUT" >/dev/null

# The last word is Gatekeeper's, on the image as a user would open it.
echo "==> Asking Gatekeeper"
spctl --assess --type open --context context:primary-signature -vv "$DMG_OUT" 2>&1 | sed 's/^/    /'
spctl --assess --type open --context context:primary-signature "$DMG_OUT" \
  || { echo "Gatekeeper does not accept the image" >&2; exit 1; }

echo "==> Done: $(pwd)/$DMG_OUT"
