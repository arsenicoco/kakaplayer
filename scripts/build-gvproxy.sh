#!/bin/bash
# Builds gvproxy (user-space networking for the engine VM; Apache-2.0,
# github.com/containers/gvisor-tap-vsock) and installs it into the app resources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${GVPROXY_VERSION:-latest}"
export GOFLAGS=-mod=mod GOBIN="$ROOT/build/gobin"
mkdir -p "$GOBIN"
go install "github.com/containers/gvisor-tap-vsock/cmd/gvproxy@${VERSION}"
install -m 755 "$GOBIN/gvproxy" "$ROOT/app/KakaPlayer/Resources/gvproxy"
go version -m "$GOBIN/gvproxy" | grep -E "^\s+mod" || true
echo "installed $(du -sh "$ROOT/app/KakaPlayer/Resources/gvproxy" | cut -f1) gvproxy"
