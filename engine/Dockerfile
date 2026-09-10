# syntax=docker/dockerfile:1
#
# KakaPlayer engine rootfs image.
#
#   * final stage is linux/amd64 (Ubuntu 22.04) because the official Ace Stream
#     engine is an x86_64 ELF binary that will run under Rosetta inside the VM.
#   * a linux/arm64 busybox stage supplies the *native* aarch64 static busybox
#     used by /init before Rosetta binfmt_misc is registered.

# ---------------------------------------------------------------------------
# Stage "bb": native arm64 static busybox + applet symlinks
# ---------------------------------------------------------------------------
FROM --platform=linux/arm64 busybox:stable-musl AS bb
# The symlink farm has to be generated *here*: the final stage is amd64 and
# cannot execute an arm64 binary during build.  `busybox --install -s <dir>`
# creates absolute symlinks pointing at the busybox we invoke (/opt/bb/busybox).
RUN mkdir -p /opt/bb \
 && cp /bin/busybox /opt/bb/busybox \
 && /opt/bb/busybox --install -s /opt/bb \
 && /opt/bb/busybox ls -l /opt/bb/sh /opt/bb/mount /opt/bb/udhcpc

# ---------------------------------------------------------------------------
# Final stage: amd64 Ubuntu 22.04 userland + Ace Stream engine
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ubuntu:22.04

ARG ACE_VERSION=3.2.11_ubuntu_22.04_x86_64_py3.10
ARG ACE_URL=https://download.acestream.media/linux/acestream_${ACE_VERSION}.tar.gz

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=UTC \
    CRYPTOGRAPHY_DONT_BUILD_RUST=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Runtime packages only.  Every Python dependency of the engine ships a
# manylinux x86_64 cp310 wheel, so no compiler / -dev packages are required
# (the pip step below enforces that with --only-binary=:all:).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        tzdata \
        iproute2 \
        iputils-ping \
        socat \
        python3.10 \
        libpython3.10 \
        python3-pip \
        python3-setuptools \
        python3-wheel \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /tmp/* /var/tmp/*

# Ace Stream engine (official x86_64 py3.10 build for Ubuntu 22.04)
RUN mkdir -p /opt/acestream \
 && curl -fSL --retry 3 "${ACE_URL}" | tar xzf - -C /opt/acestream \
 && chmod -R a+rX /opt/acestream \
 && chmod 755 /opt/acestream/start-engine /opt/acestream/acestreamengine

# Python dependencies.  --only-binary=:all: guarantees a wheel-only install:
# if upstream ever stops shipping a wheel the build fails loudly instead of
# silently pulling in a source build that needs a toolchain we do not have.
RUN python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel \
 && python3 -m pip install --no-cache-dir --only-binary=:all: \
        -r /opt/acestream/requirements.txt \
 && python3 -m pip freeze > /opt/acestream/installed-packages.txt \
 && rm -rf /root/.cache /tmp/* /var/tmp/*

# In-build smoke test: the engine binary must load libpython + its own libs.
RUN /opt/acestream/start-engine --version \
 && /opt/acestream/start-engine --version | grep -q . \
 && echo "engine version OK"

# Native arm64 busybox + applet symlinks for /init (never executed at build time)
COPY --from=bb /opt/bb /opt/bb

# VM boot glue
COPY init /init
COPY udhcpc.sh /etc/udhcpc.sh
COPY poweroff.sh /opt/kaka/poweroff.sh
RUN chmod 755 /init /etc/udhcpc.sh /opt/kaka/poweroff.sh \
 && mkdir -p /var/cache/acestream /var/lib/acestream /run/rosetta /var/log \
 && : > /var/log/acestream.log

EXPOSE 6878/tcp
