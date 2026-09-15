#!/bin/bash
# Downloads the prebuilt VLCKit 4.0 xcframework and installs the macOS slice plus
# every iOS slice (device and simulator) into
# app/Packages/VLCKitBinary/VLCKit.xcframework.
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
# The slice names come from the zip's own Info.plist, so a respin that renames a
# slice needs no change here: we keep whatever is prefixed macos- or ios-.
SLICES="$(python3 - "$DL/VLCKit.xcframework/Info.plist" "$PKG/VLCKit.xcframework/Info.plist" <<'PY'
import plistlib, sys

KEEP_PREFIXES = ("macos-", "ios-")

with open(sys.argv[1], "rb") as src:
    plist = plistlib.load(src)

kept = [lib for lib in plist["AvailableLibraries"]
        if str(lib.get("LibraryIdentifier", "")).startswith(KEEP_PREFIXES)]
for prefix in KEEP_PREFIXES:
    if not any(lib["LibraryIdentifier"].startswith(prefix) for lib in kept):
        sys.exit("no %s* slice in %s" % (prefix, sys.argv[1]))

plist["AvailableLibraries"] = kept
with open(sys.argv[2], "wb") as dst:
    plistlib.dump(plist, dst)

print("\n".join(lib["LibraryIdentifier"] for lib in kept))
PY
)"
while IFS= read -r slice; do
  cp -R "$DL/VLCKit.xcframework/$slice" "$PKG/VLCKit.xcframework/"
done <<< "$SLICES"
cp COPYING.txt "$PKG/VLCKit-COPYING.txt"
echo "installed $(du -sh "$PKG/VLCKit.xcframework" | cut -f1) into $PKG"
echo "slices: $(echo "$SLICES" | tr '\n' ' ')"
