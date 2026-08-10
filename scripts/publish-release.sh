#!/bin/bash
# Publish a GitHub release for an already-pushed tag: create the release,
# build the .dmg, and upload it. Called by git-release as cmd3 (after the
# tag has been pushed to origin). Safe to re-run by hand if a step fails.
# Usage: scripts/publish-release.sh --release v1.2.3
set -euo pipefail

cd "$(dirname "$0")/.."

TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) TAG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TAG" ] || { echo "publish-release: --release <tag> is required" >&2; exit 2; }

command -v gh >/dev/null || { echo "publish-release: gh CLI not found" >&2; exit 1; }

# The tag is pushed before cmd3 runs, but fetch to be sure it's visible locally.
git fetch --tags --quiet origin

echo "==> Creating GitHub release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "    release already exists, reusing it"
else
  gh release create "$TAG" --title "$TAG" --verify-tag --generate-notes
fi

echo "==> Building disk image"
scripts/make-dmg.sh

ASSET="Wietty.${TAG}.dmg"
cp -f Wietty.dmg "$ASSET"
trap 'rm -f "$ASSET"' EXIT

echo "==> Uploading $ASSET"
gh release upload "$TAG" "$ASSET" --clobber

echo "==> Published $TAG: $(gh release view "$TAG" --json url --jq .url)"
