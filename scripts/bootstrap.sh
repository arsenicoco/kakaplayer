#!/bin/bash
# One-time (idempotent) setup: fetches VLCKit, the guest kernel and gvproxy,
# generates the icons, and builds the Ace Stream engine image. Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> guest kernel";      [[ -f build/kernel/vmlinux-arm64 ]] || scripts/fetch-kernel.sh
echo "==> VLCKit";            [[ -d app/Packages/VLCKitBinary/VLCKit.xcframework/macos-arm64_x86_64 ]] || scripts/fetch-vlckit.sh
echo "==> gvproxy";           [[ -f app/KakaPlayer/Resources/gvproxy ]] || scripts/build-gvproxy.sh
echo "==> icons";             [[ -f app/KakaPlayer/Resources/AppIcon.icns && -f app/KakaPlayer/Resources/AppMark.png ]] || scripts/make-icon.sh
echo "==> engine image";      [[ -f build/rootfs.img.xz ]] || engine/build-rootfs.sh
echo "==> bootstrap complete. Next: scripts/build-app.sh"
