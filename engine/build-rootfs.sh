#!/usr/bin/env bash
#
# KakaPlayer engine rootfs builder.
#
# Produces build/rootfs.img (ext4, label "kakaroot") and build/rootfs.img.xz
# from engine/Dockerfile + engine/init.
#
# Usage:  engine/build-rootfs.sh [--skip-validate] [--skip-xz]
#
# Env overrides:
#   IMG_SIZE   ext4 image size            (default 4G)
#   XZ_LEVEL   xz compression level       (default 6, use 3 if too slow)
#   IMAGE      docker image tag           (default kakaplayer-engine)
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$ENGINE_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

DOCKER=${DOCKER:-/usr/local/bin/docker}
ORBCTL=${ORBCTL:-/usr/local/bin/orbctl}
IMAGE=${IMAGE:-kakaplayer-engine}
IMG_SIZE=${IMG_SIZE:-4G}
XZ_LEVEL=${XZ_LEVEL:-6}
BUILDER_IMAGE=${BUILDER_IMAGE:-alpine:3.20}

SKIP_VALIDATE=0
SKIP_XZ=0
for a in "$@"; do
    case "$a" in
        --skip-validate) SKIP_VALIDATE=1 ;;
        --skip-xz)       SKIP_XZ=1 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 0. OrbStack
# ---------------------------------------------------------------------------
say "Ensuring OrbStack docker is running"
if ! "$DOCKER" info >/dev/null 2>&1; then
    "$ORBCTL" start
    for i in $(seq 1 90); do
        "$DOCKER" info >/dev/null 2>&1 && break
        sleep 1
    done
fi
"$DOCKER" info >/dev/null 2>&1 || fail "docker is not available"
echo "docker OK"

# ---------------------------------------------------------------------------
# 1. Static checks on the boot scripts (arm64 busybox sh -n)
# ---------------------------------------------------------------------------
say "Syntax-checking boot scripts with native arm64 busybox sh"
"$DOCKER" run --rm --platform linux/arm64 -v "$ENGINE_DIR:/e:ro" busybox:stable-musl \
    sh -c 'set -e
           for f in /e/init /e/udhcpc.sh /e/poweroff.sh; do
               sh -n "$f" && echo "syntax OK: $f"
           done
           # The binfmt magic/mask must be exactly 20 bytes each.
           printf ":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/run/rosetta/rosetta:OCF\n" | hexdump -C | head -5' \
    || fail "boot script syntax check failed"

# Also exercise the udhcpc callback with a fake lease environment.
"$DOCKER" run --rm --platform linux/arm64 -v "$ENGINE_DIR:/e:ro" busybox:stable-musl \
    sh -c 'cp /e/udhcpc.sh /tmp/u.sh && chmod +x /tmp/u.sh
           export interface=eth0 ip=192.168.64.7 mask=24 router=192.168.64.1 dns="192.168.64.1 1.1.1.1" domain=local
           sh /tmp/u.sh bound   2>&1 | grep KAKA-DHCP
           sh /tmp/u.sh renew   2>&1 | grep KAKA-DHCP
           sh /tmp/u.sh deconfig >/dev/null 2>&1; echo "udhcpc.sh deconfig rc=$?"
           echo "--- generated resolv.conf ---"; cat /etc/resolv.conf' \
    || fail "udhcpc.sh dry-run failed"

# ---------------------------------------------------------------------------
# 2. Build the amd64 engine image
# ---------------------------------------------------------------------------
say "Building $IMAGE (linux/amd64)"
"$DOCKER" build --platform linux/amd64 -t "$IMAGE" "$ENGINE_DIR"

# ---------------------------------------------------------------------------
# 3. Validation: run the engine in the container and query its HTTP API
# ---------------------------------------------------------------------------
if [ "$SKIP_VALIDATE" = "0" ]; then
    say "Validating engine HTTP API inside the amd64 container"
    "$DOCKER" rm -f kaka-test >/dev/null 2>&1 || true
    "$DOCKER" run --rm -d --platform linux/amd64 -p 6878:6878 --name kaka-test "$IMAGE" \
        /opt/acestream/start-engine --client-console --http-port 6878 --bind-all --log-stdout >/dev/null

    VERSION_JSON=""
    for i in $(seq 1 90); do
        VERSION_JSON=$(curl -fsS --max-time 3 \
            'http://127.0.0.1:6878/webui/api/service?method=get_version' 2>/dev/null || true)
        if [ -n "$VERSION_JSON" ]; then
            echo "engine answered after ${i}s"
            break
        fi
        sleep 1
    done

    if [ -n "$VERSION_JSON" ]; then
        echo "get_version -> $VERSION_JSON"
        echo "$VERSION_JSON" > "$BUILD_DIR/engine-get_version.json"
    else
        echo "--- container log tail ---"
        "$DOCKER" logs --tail 60 kaka-test 2>&1 || true
        "$DOCKER" rm -f kaka-test >/dev/null 2>&1 || true
        fail "engine did not answer on http://127.0.0.1:6878 within 90s"
    fi

    "$DOCKER" rm -f kaka-test >/dev/null 2>&1 || true
else
    say "Skipping engine validation (--skip-validate)"
fi

# ---------------------------------------------------------------------------
# 4. Export the container filesystem
# ---------------------------------------------------------------------------
say "Exporting container filesystem to build/rootfs.tar"
CID=$("$DOCKER" create --platform linux/amd64 "$IMAGE" /bin/true)
trap '"$DOCKER" rm -f "$CID" >/dev/null 2>&1 || true' EXIT
"$DOCKER" export "$CID" -o "$BUILD_DIR/rootfs.tar"
"$DOCKER" rm -f "$CID" >/dev/null 2>&1 || true
trap - EXIT
ls -lh "$BUILD_DIR/rootfs.tar"

# ---------------------------------------------------------------------------
# 5. Assemble the ext4 image (needs a Linux container: mke2fs -d)
# ---------------------------------------------------------------------------
say "Assembling ext4 image (${IMG_SIZE}, label kakaroot)"
rm -f "$BUILD_DIR/rootfs.img" "$BUILD_DIR/rootfs.img.xz"

"$DOCKER" run --rm \
    -e IMG_SIZE="$IMG_SIZE" -e XZ_LEVEL="$XZ_LEVEL" -e SKIP_XZ="$SKIP_XZ" \
    -v "$BUILD_DIR:/out" \
    -v "$ENGINE_DIR:/src:ro" \
    "$BUILDER_IMAGE" sh -euc '
    apk add --no-cache e2fsprogs xz tar file >/dev/null

    mkdir -p /rootfs
    echo "extracting rootfs.tar ..."
    tar -xpf /out/rootfs.tar -C /rootfs --numeric-owner

    # --- boot glue (authoritative copies straight from engine/) -------------
    install -m 0755 /src/init        /rootfs/init
    install -m 0755 /src/udhcpc.sh   /rootfs/etc/udhcpc.sh
    install -d -m 0755              /rootfs/opt/kaka
    install -m 0755 /src/poweroff.sh /rootfs/opt/kaka/poweroff.sh

    # --- runtime directories ------------------------------------------------
    install -d -m 0755 /rootfs/var/cache/acestream \
                       /rootfs/var/lib/acestream \
                       /rootfs/run/rosetta \
                       /rootfs/var/log \
                       /rootfs/proc /rootfs/sys /rootfs/dev/pts /rootfs/dev/shm
    install -d -m 1777 /rootfs/tmp
    : > /rootfs/var/log/acestream.log

    # --- /etc/resolv.conf must be a writable REGULAR file -------------------
    if [ -L /rootfs/etc/resolv.conf ]; then
        echo "removing /etc/resolv.conf symlink"
        rm -f /rootfs/etc/resolv.conf
    fi
    # docker export ships a zero-byte /etc/resolv.conf; seed it so DNS works
    # even before the first DHCP lease.
    [ -s /rootfs/etc/resolv.conf ] || printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /rootfs/etc/resolv.conf
    chmod 0644 /rootfs/etc/resolv.conf

    echo kakaplayer > /rootfs/etc/hostname
    printf "127.0.0.1 localhost\n127.0.1.1 kakaplayer\n" > /rootfs/etc/hosts
    [ -e /rootfs/etc/mtab ] || ln -s /proc/mounts /rootfs/etc/mtab

    # docker export leaves this behind
    rm -f /rootfs/.dockerenv

    # --- sanity checks ------------------------------------------------------
    echo "--- busybox check ---"
    file /rootfs/opt/bb/busybox
    file /rootfs/opt/bb/busybox | grep -q "ARM aarch64" \
        || { echo "FATAL: /opt/bb/busybox is not aarch64"; exit 1; }
    # busybox:stable-musl is built static-PIE; accept either wording.
    file /rootfs/opt/bb/busybox | grep -Eq "statically linked|static-pie linked" \
        || { echo "FATAL: /opt/bb/busybox is not statically linked"; exit 1; }
    cp /rootfs/opt/bb/busybox /out/busybox-arm64
    ls -l /rootfs/opt/bb/sh /rootfs/opt/bb/mount /rootfs/opt/bb/udhcpc /rootfs/opt/bb/ip
    echo "--- engine binary ---"
    file /rootfs/opt/acestream/acestreamengine
    echo "--- /init ---"
    head -1 /rootfs/init; ls -l /rootfs/init
    echo "--- rootfs size ---"
    du -sh /rootfs

    # --- ext4 ---------------------------------------------------------------
    truncate -s "$IMG_SIZE" /out/rootfs.img
    mke2fs -t ext4 -F -L kakaroot -d /rootfs /out/rootfs.img
    e2fsck -fn /out/rootfs.img || true

    if [ "$SKIP_XZ" = "0" ]; then
        echo "compressing (xz -T0 -${XZ_LEVEL}) ..."
        xz -T0 -"${XZ_LEVEL}" --keep --force /out/rootfs.img
    fi

    ls -l /out
'

# ---------------------------------------------------------------------------
# 6. Host-side verification + sizes
# ---------------------------------------------------------------------------
say "Host verification"
file "$BUILD_DIR/busybox-arm64"
file "$BUILD_DIR/busybox-arm64" | grep -q "ARM aarch64" || fail "busybox is not aarch64"
file "$BUILD_DIR/busybox-arm64" | grep -Eq "statically linked|static-pie linked" \
    || fail "busybox is not statically linked"

say "Artifacts"
for f in rootfs.tar rootfs.img rootfs.img.xz engine-get_version.json; do
    [ -e "$BUILD_DIR/$f" ] && ls -lh "$BUILD_DIR/$f"
done
echo
echo "Apparent vs on-disk size of rootfs.img:"
du -h  "$BUILD_DIR/rootfs.img"  2>/dev/null || true
du -Ah "$BUILD_DIR/rootfs.img"  2>/dev/null || true

say "Done. Boot with: console=hvc0 root=/dev/vda rw init=/init  (virtiofs tag 'rosetta', vsock 6878/6880)"
