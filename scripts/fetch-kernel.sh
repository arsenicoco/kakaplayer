#!/bin/bash
# Fetches the arm64 guest kernel (Kata Containers static release, same one Apple's
# Containerization framework uses) into build/kernel/vmlinux-arm64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KATA_VERSION="${KATA_VERSION:-3.17.0}"
URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.xz"
OUT="$ROOT/build/kernel"
mkdir -p "$OUT"
cd "$OUT"
[[ -f kata.tar.xz ]] || curl -SsL -o kata.tar.xz "$URL"
tar -xJf kata.tar.xz './opt/kata/share/kata-containers/'
cp -L opt/kata/share/kata-containers/vmlinux.container vmlinux-arm64
file vmlinux-arm64
