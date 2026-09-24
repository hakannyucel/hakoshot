#!/usr/bin/env bash
# Debug build of HakoShot into ./build (derived data). Prints the .app path.
# Usage: scripts/build.sh [extra xcodebuild args...]   (VERBOSE=1 for full log, DERIVED_DATA=path to override ./build)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED="${DERIVED_DATA:-$ROOT/build}"
QUIET=(-quiet)
[[ "${VERBOSE:-0}" == "1" ]] && QUIET=()

xcodebuild build \
  -project HakoShot.xcodeproj \
  -scheme HakoShot \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED" \
  ${QUIET[@]+"${QUIET[@]}"} \
  "$@"

echo "$DERIVED/Build/Products/$CONFIGURATION/HakoShot.app"
