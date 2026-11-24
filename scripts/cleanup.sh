#!/usr/bin/env bash
#
# cleanup.sh
#
# Removes what builds and test runs leave behind and nothing needs again:
#
#   1. `TemporaryDirectory.*` in the temporary directory. Foundation creates one
#      for every atomic file write and a process that is killed (a test host
#      usually is) never removes its own. They belong to no one in particular,
#      so only those untouched for an hour go: a younger one may be a write in
#      progress, of this app or of any other.
#   2. `build/` in the repository. No script writes there; it appears when
#      xcodebuild is run with a build directory of its own, and everything in it
#      is rebuilt on demand.
#   3. The intermediates and caches in `build-release/`, the derived data of
#      `scripts/make-dmg.sh`. The built app (`Build/Products`) and the resolved
#      packages (`SourcePackages`) stay: the first is the last release build,
#      the second holds two binary artifacts whose download can hang on a
#      keychain prompt (see CLAUDE.md, "A first build can hang").
#
# Usage: scripts/cleanup.sh [--dry-run] [--all]
#   --dry-run  print what would go and how much it frees, remove nothing
#   --all      remove `build-release/` as a whole, products and packages too

set -euo pipefail

DRY_RUN=0
ALL=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument ${arg}" >&2; exit 2 ;;
  esac
done

# Run from the repository root regardless of where the script is invoked.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# A release build writes into build-release while it runs.
if pgrep -f 'xcodebuild.*build-release' >/dev/null; then
  echo "error: a release build is running in build-release. Wait for it to finish." >&2
  exit 1
fi

size_of() {
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

# Removes one path inside the repository, or says what it would remove.
remove() {
  local path="$1"
  [ -e "${path}" ] || return 0
  if [ "${DRY_RUN}" = 1 ]; then
    echo "would remove ${path} ($(size_of "${path}"))"
  else
    echo "removing ${path} ($(size_of "${path}"))"
    rm -rf -- "${path}"
  fi
}

# 1. Foundation's leftovers in the temporary directory.
TMP="${TMPDIR:-}"
if [ -z "${TMP}" ] || [ ! -d "${TMP}" ]; then
  echo "TMPDIR is not set to a directory, so the temporary directory is skipped."
else
  COUNT="$(find "${TMP%/}" -maxdepth 1 -type d -name 'TemporaryDirectory.*' -mmin +60 | wc -l | tr -d ' ')"
  if [ "${DRY_RUN}" = 1 ]; then
    echo "would remove ${COUNT} TemporaryDirectory.* older than an hour from ${TMP%/}"
  else
    echo "removing ${COUNT} TemporaryDirectory.* older than an hour from ${TMP%/}"
    find "${TMP%/}" -maxdepth 1 -type d -name 'TemporaryDirectory.*' -mmin +60 \
      -exec rm -rf -- {} +
  fi
fi

# 2. The stray build directory.
remove "build"

# 3. The release build's derived data.
if [ "${ALL}" = 1 ]; then
  remove "build-release"
else
  remove "build-release/Build/Intermediates.noindex"
  remove "build-release/SDKExplicitPrecompiledModules"
  remove "build-release/SDKStatCaches.noindex"
  remove "build-release/ModuleCache.noindex"
  remove "build-release/CompilationCache.noindex"
  remove "build-release/Logs"
  remove "build-release/.DS_Store"
fi

if [ "${DRY_RUN}" = 1 ]; then
  echo "Dry run: nothing was removed."
else
  echo "Done."
fi
