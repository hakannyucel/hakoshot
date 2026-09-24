#!/usr/bin/env bash
# Runs HakoKit unit tests (swift test) then the app test target (xcodebuild test).
# Usage: scripts/test.sh   (VERBOSE=1 for full log, DERIVED_DATA / SWIFTPM_SCRATCH to isolate parallel runs)
set -euo pipefail
# Tests use throwaway UserDefaults suites (com.hakanyucel.hakoshot.tests.*);
# cfprefsd leaves their plists behind, so remove them on every exit.
trap 'rm -f "$HOME"/Library/Preferences/com.hakanyucel.hakoshot.tests.*.plist' EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QUIET=(-quiet)
SWIFT_QUIET=(--quiet)
if [[ "${VERBOSE:-0}" == "1" ]]; then QUIET=(); SWIFT_QUIET=(); fi

echo "==> swift test (Packages/HakoKit)"
swift test --package-path Packages/HakoKit ${SWIFTPM_SCRATCH:+--scratch-path "$SWIFTPM_SCRATCH"} ${SWIFT_QUIET[@]+"${SWIFT_QUIET[@]}"}

echo "==> xcodebuild test (HakoShot)"
xcodebuild test \
  -project HakoShot.xcodeproj \
  -scheme HakoShot \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "${DERIVED_DATA:-$ROOT/build}" \
  ${QUIET[@]+"${QUIET[@]}"}

echo "==> all tests passed"
