# Third-party components

KakaPlayer's own source code is MIT-licensed (see `LICENSE`). The packaged
`.app` bundles or downloads at build time the following third-party components,
each under its own license. Sources are linked so anyone can obtain and rebuild
them, satisfying the source-availability terms of the copyleft licenses below.

| Component | Role in the app | License | Source |
|-----------|-----------------|---------|--------|
| **VLCKit 4.0** | Media playback (embedded framework) | LGPL-2.1-or-later | https://code.videolan.org/videolan/VLCKit |
| **Ace Stream Engine 3.2.11** | P2P streaming engine (runs in the Linux VM) | Ace Stream User Agreement | https://acestream.org/about/license · https://docs.acestream.net |
| **gvisor-tap-vsock (gvproxy)** | User-space guest networking | Apache-2.0 | https://github.com/containers/gvisor-tap-vsock |
| **Kata Containers kernel** (`vmlinux`) | Linux guest kernel | GPL-2.0-only | https://github.com/kata-containers/kata-containers |
| **BusyBox** | Guest init / userland (`/init`) | GPL-2.0-only | https://busybox.net |
| **Ubuntu 22.04 base + Python 3.10** | Guest userland the engine needs | Various (mostly GPL/LGPL/MIT/BSD) | https://ubuntu.com · https://hub.docker.com/_/ubuntu |
| **socat** | vsock↔TCP bridge in the guest | GPL-2.0 | http://www.dest-unreach.org/socat/ |
| **Apple Virtualization.framework** | Hosts the Linux VM | Apple SDK (system framework) | macOS |

## Notes on the copyleft components

- **VLCKit (LGPL-2.1)** is bundled as an unmodified **dynamic** framework
  (`KakaPlayer.app/Contents/Frameworks/VLCKit.framework`). Its license text ships
  in the package (`VLCKit-COPYING.txt`) and users may replace the framework with
  their own build.
- **Linux kernel, BusyBox, socat (GPL-2.0)** are redistributed unmodified inside
  the compressed guest image. Their complete corresponding source is available
  from the upstream projects linked above at the pinned versions
  (Kata `3.17.0`, Ubuntu `22.04`, BusyBox `1.36.1`).
- **Ace Stream Engine** is downloaded at build time from the official
  `download.acestream.media` server and redistributed **unchanged**, which the
  Ace Stream User Agreement permits for non-commercial use. KakaPlayer does not
  modify, decompile, or repackage the engine, and does not include any Ace Stream
  content or channel lists.

If you build from source, `scripts/bootstrap.sh` fetches each component directly
from its upstream, so nothing proprietary is stored in this repository.
