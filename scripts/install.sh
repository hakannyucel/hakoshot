#!/usr/bin/env bash
# Builds HakoShot, quits the running copy, installs to /Applications and relaunches.
# Always running from the same path keeps TCC grants and Login Items stable (plan §2.2).
# Usage: scripts/install.sh [--no-build]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/HakoShot.app"
BUNDLE_ID="com.hakanyucel.HakoShot"

if [[ "${1:-}" == "--no-build" ]]; then
  APP="$ROOT/build/Build/Products/${CONFIGURATION:-Debug}/HakoShot.app"
else
  APP="$("$ROOT/scripts/build.sh" | tail -n 1)"
fi
[[ -d "$APP" ]] || { echo "error: built app not found at $APP" >&2; exit 1; }

# Quit gracefully, then force if it is still alive after ~5 s.
if pgrep -x HakoShot >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..50}; do pgrep -x HakoShot >/dev/null || break; sleep 0.1; done
  pkill -x HakoShot 2>/dev/null || true
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "installed and launched: $DEST"
