#!/bin/bash
# Builds the app and publishes (or updates) a GitHub release with the DMG.
# Usage: scripts/release.sh vX.Y.Z ["release notes"]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
TAG="${1:?usage: release.sh vX.Y.Z [notes]}"
NOTES="${2:-KakaPlayer $TAG}"
CONFIG=Release scripts/build-app.sh
DMG="dist/KakaPlayer.dmg"
[[ -f "$DMG" ]] || { echo "missing $DMG"; exit 1; }
OUT="dist/KakaPlayer-$TAG.dmg"; cp -f "$DMG" "$OUT"
git tag -f "$TAG" && git push -f origin "$TAG" 2>/dev/null || git push origin "$TAG" || true
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$OUT" --clobber
else
  gh release create "$TAG" "$OUT" --title "KakaPlayer $TAG" --notes "$NOTES"
fi
echo "released $TAG with $OUT"
