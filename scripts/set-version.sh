#!/bin/bash
# Set MARKETING_VERSION in project.yml to match a release tag.
# Called by git-release as cmd1 (before the tag is created), so the version
# bump is baked into the tagged commit. git-release stages and commits
# project.yml afterwards.
# Usage: scripts/set-version.sh --release v1.2.3
set -euo pipefail

cd "$(dirname "$0")/.."

TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) TAG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TAG" ] || { echo "set-version: --release <tag> is required" >&2; exit 2; }

# Strip a leading v/V; MARKETING_VERSION is a plain dotted number.
VERSION="${TAG#[vV]}"

case "$VERSION" in
  *[!0-9.]*|"") echo "set-version: '$TAG' is not a numeric version" >&2; exit 2 ;;
esac

grep -q 'MARKETING_VERSION:' project.yml || {
  echo "set-version: MARKETING_VERSION not found in project.yml" >&2; exit 1; }

# Replace the value while preserving indentation and quoting.
/usr/bin/sed -i '' -E "s/(MARKETING_VERSION:[[:space:]]*\").*(\")/\1${VERSION}\2/" project.yml

echo "set-version: MARKETING_VERSION -> ${VERSION}"
