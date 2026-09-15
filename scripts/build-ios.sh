#!/bin/bash
# Builds KakaPlayerMobile (the iPhone/iPad client).
#
# Default: an unsigned build for the iOS Simulator named by SIMULATOR (KakaTest),
# created on the fly if it does not exist yet.
#
#   scripts/build-ios.sh
#
# With a signing team in the environment it builds for a device instead, using
# automatic signing (no team is checked into project.yml):
#
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/build-ios.sh
#
# Prerequisites: Xcode 26+, xcodegen (brew install xcodegen) and the VLCKit
# xcframework in app/Packages/VLCKitBinary (scripts/fetch-vlckit.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
BUILD="$ROOT/build"
CONFIG="${CONFIG:-Debug}"
SIMULATOR="${SIMULATOR:-KakaTest}"
DERIVED="$BUILD/DerivedData-ios"
PACKAGES="$BUILD/SourcePackages"

command -v xcodegen >/dev/null || {
  echo "xcodegen is not installed. Run: brew install xcodegen"
  exit 1
}
[[ -d "$APP_DIR/Packages/VLCKitBinary/VLCKit.xcframework" ]] || {
  echo "VLCKit.xcframework is missing. Run: scripts/fetch-vlckit.sh"
  exit 1
}

# Creates the simulator on first run: first available iPhone device type, newest iOS runtime.
ensure_simulator() {
  # `available` only: a device on a deleted runtime still lists, but cannot be built for.
  if xcrun simctl list devices available | grep -q " $SIMULATOR ("; then return; fi
  local device_type runtime
  device_type="$(xcrun simctl list devicetypes --json \
    | /usr/bin/python3 -c 'import json,sys; ts=[t for t in json.load(sys.stdin)["devicetypes"] if "iPhone" in t["name"]]; print(ts[0]["identifier"] if ts else "")')"
  runtime="$(xcrun simctl list runtimes --json \
    | /usr/bin/python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["platform"]=="iOS"]; rs.sort(key=lambda r:[int(p) for p in r["version"].split(".")]); print(rs[-1]["identifier"] if rs else "")')"
  [[ -n "$device_type" && -n "$runtime" ]] || { echo "No iPhone device type or iOS runtime is available; install one in Xcode."; exit 1; }
  echo "creating simulator $SIMULATOR ($device_type on $runtime)"
  xcrun simctl create "$SIMULATOR" "$device_type" "$runtime" >/dev/null
}

cd "$APP_DIR"
xcodegen generate --quiet

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "building for a device with team $DEVELOPMENT_TEAM"
  DESTINATION='generic/platform=iOS'
  # -allowProvisioningUpdates: no profile for dev.kakaplayer.mobile exists until Xcode
  # creates one, and without this the first device build just fails asking for it.
  SIGNING=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  PRODUCT_DIR="$DERIVED/Build/Products/$CONFIG-iphoneos"
else
  ensure_simulator
  DESTINATION="platform=iOS Simulator,name=$SIMULATOR"
  SIGNING=(CODE_SIGNING_ALLOWED=NO)
  PRODUCT_DIR="$DERIVED/Build/Products/$CONFIG-iphonesimulator"
fi

LOG="$BUILD/build-ios.log"
mkdir -p "$BUILD"
set +e
xcodebuild -project KakaPlayer.xcodeproj -scheme KakaPlayerMobile -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -destination "$DESTINATION" \
  "${SIGNING[@]}" \
  build > "$LOG" 2>&1
status=$?
set -e
grep -E "error:|warning: .*Swift|^\*\* BUILD" "$LOG" | head -40 || true
[[ $status -eq 0 ]] || { echo "build failed (full log: $LOG)"; exit "$status"; }

APP="$PRODUCT_DIR/KakaPlayerMobile.app"
[[ -d "$APP" ]] || { echo "build reported success but $APP is missing (full log: $LOG)"; exit 1; }
echo "OK: $APP"
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "install it with: xcrun simctl boot $SIMULATOR && xcrun simctl install $SIMULATOR \"$APP\""
fi
