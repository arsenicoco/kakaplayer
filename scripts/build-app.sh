#!/bin/bash
# Builds KakaPlayer.app (ad-hoc signed, with the virtualization entitlement),
# bundles the guest kernel + rootfs, and produces dist/KakaPlayer.dmg.
#
# Prerequisites: Xcode 26+, xcodegen (brew install xcodegen), and the bundle
# resources produced by scripts/bootstrap.sh. Run that once first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
RES="$APP_DIR/KakaPlayer/Resources"
CONFIG="${CONFIG:-Release}"

missing=0
check() { [[ -e "$1" ]] || { echo "  missing: $1"; missing=1; }; }
check "$BUILD/kernel/vmlinux-arm64"
check "$BUILD/rootfs.img.xz"
check "$APP_DIR/Packages/VLCKitBinary/VLCKit.xcframework/macos-arm64_x86_64"
check "$RES/gvproxy"
check "$RES/AppIcon.icns"
check "$RES/AppMark.png"
if [[ "$missing" == 1 ]]; then
  echo "Bundle resources are not set up. Run: scripts/bootstrap.sh"
  exit 1
fi

mkdir -p "$RES" "$DIST"
cp -f "$BUILD/kernel/vmlinux-arm64" "$RES/vmlinux-arm64"
cp -f "$BUILD/rootfs.img.xz" "$RES/rootfs.img.xz"
# Version stamp: the app re-extracts the image when this changes.
shasum -a 256 "$BUILD/rootfs.img.xz" | cut -c1-16 > "$RES/rootfs.version"
echo "rootfs version: $(cat "$RES/rootfs.version")"

cd "$APP_DIR"
xcodegen generate --quiet
xcodebuild -project KakaPlayer.xcodeproj -scheme KakaPlayer -configuration "$CONFIG" \
  -derivedDataPath "$BUILD/DerivedData" \
  -clonedSourcePackagesDirPath "$BUILD/SourcePackages" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES \
  build | grep -E "error:|warning: .*Swift|BUILD|Signing" || true

APP="$BUILD/DerivedData/Build/Products/$CONFIG/KakaPlayer.app"
[[ -d "$APP" ]] || { echo "build failed: $APP not found"; exit 1; }

# Re-sign the whole bundle ad-hoc with the entitlement (deep, so VLCKit is covered too).
codesign --force --deep --sign - --timestamp=none \
  --entitlements "$APP_DIR/KakaPlayer/KakaPlayer.entitlements" "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q virtualization || { echo "entitlement missing"; exit 1; }

rm -rf "$DIST/KakaPlayer.app"
ditto "$APP" "$DIST/KakaPlayer.app"
du -sh "$DIST/KakaPlayer.app"

rm -f "$DIST/KakaPlayer.dmg"
STAGE="$BUILD/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$DIST/KakaPlayer.app" "$STAGE/KakaPlayer.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname KakaPlayer -srcfolder "$STAGE" -ov -format UDZO -quiet "$DIST/KakaPlayer.dmg"
rm -rf "$STAGE"
ls -lh "$DIST"
echo "OK: $DIST/KakaPlayer.app and $DIST/KakaPlayer.dmg"
