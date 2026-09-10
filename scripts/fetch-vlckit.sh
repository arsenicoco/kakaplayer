#!/bin/bash
# Downloads the prebuilt VLCKit 4.0 xcframework and installs only the macOS slice
# into app/Packages/VLCKitBinary/VLCKit.xcframework.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260831-1526.zip"
SHA="c61a42052ec4c1315325fba81f8893f4ccf639d92bf61dd1b3c37c3a2f26b8e3"
DL="$ROOT/build/vlckit"; PKG="$ROOT/app/Packages/VLCKitBinary"
mkdir -p "$DL"
cd "$DL"
[[ -f VLCKit-4.0.zip ]] || curl -SL -C - --retry 20 --retry-all-errors -o VLCKit-4.0.zip "$URL"
echo "$SHA  VLCKit-4.0.zip" | shasum -a 256 -c -
unzip -q -o VLCKit-4.0.zip
rm -rf "$PKG/VLCKit.xcframework"; mkdir -p "$PKG/VLCKit.xcframework"
cp -R VLCKit.xcframework/macos-arm64_x86_64 "$PKG/VLCKit.xcframework/"
python3 - "$DL/VLCKit.xcframework/Info.plist" "$PKG/VLCKit.xcframework/Info.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
p["AvailableLibraries"] = [l for l in p["AvailableLibraries"] if l.get("LibraryIdentifier") == "macos-arm64_x86_64"]
plistlib.dump(p, open(sys.argv[2], "wb"))
PY
cp COPYING.txt "$PKG/VLCKit-COPYING.txt"
echo "installed $(du -sh "$PKG/VLCKit.xcframework" | cut -f1) into $PKG"
