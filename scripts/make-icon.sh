#!/bin/bash
# Turns a source PNG (ideally 1024x1024+, transparent background) into
#   app/KakaPlayer/Resources/AppIcon.icns   (the app icon)
#   app/KakaPlayer/Resources/AppMark.png    (512px mark shown on the idle screen)
# Usage: scripts/make-icon.sh [source.png]   (defaults to ./icon.png)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/icon.png}"
[[ -f "$SRC" ]] || { echo "no such file: $SRC"; exit 1; }
RES="$ROOT/app/KakaPlayer/Resources"; mkdir -p "$RES"
TMP="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$TMP"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz             "$SRC" --out "$TMP/icon_${sz}x${sz}.png"    >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$SRC" --out "$TMP/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP" -o "$RES/AppIcon.icns"
rm -rf "$(dirname "$TMP")"
sips -s format png -Z 512 "$SRC" --out "$RES/AppMark.png" >/dev/null
echo "wrote AppIcon.icns ($(du -h "$RES/AppIcon.icns" | cut -f1)) and AppMark.png"
