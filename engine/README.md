# KakaPlayer engine rootfs

Builds the minimal Linux root filesystem that KakaPlayer boots inside an Apple
Virtualization.framework VM (arm64 Kata kernel) to run the official **Ace Stream
engine 3.2.11** — an *x86_64* Linux build executed through **Rosetta**.

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Two stages. `bb` = `linux/arm64 busybox:stable-musl`, provides the **native aarch64 static busybox** plus its applet symlink farm at `/opt/bb`. Final stage = `linux/amd64 ubuntu:22.04` with Python 3.10, socat, iproute2 and the Ace Stream engine in `/opt/acestream`. |
| `init` | PID 1. Shebang `#!/opt/bb/busybox sh`. Mounts, Rosetta binfmt registration, DHCP, vsock bridges, engine supervision loop. Installed as `/init`, mode 755. |
| `udhcpc.sh` | busybox `udhcpc` callback (`deconfig` / `bound` / `renew` / `leasefail`). Installed as `/etc/udhcpc.sh`. |
| `poweroff.sh` | Clean-shutdown handler exec'd by socat when the host connects to vsock **6880**. Installed as `/opt/kaka/poweroff.sh`. |
| `build-rootfs.sh` | Reproducible end-to-end build: OrbStack → docker build → engine HTTP validation → `docker export` → ext4 image → `xz`. |

Build outputs land in `../build/`:

* `rootfs.img` — 4 GiB ext4, label `kakaroot` (sparse; ~390 MB actually used)
* `rootfs.img.xz` — compressed image for shipping
* `rootfs.tar` — intermediate container export
* `busybox-arm64` — the extracted busybox, for `file(1)` verification
* `engine-get_version.json` — captured validation response

## Boot contract

```
kernel cmdline : console=hvc0 root=/dev/vda rw init=/init
root disk      : /dev/vda, ext4, label kakaroot
virtiofs tag   : rosetta   ->  mounted at /run/rosetta
vsock 6878     : host -> guest, bridged to 127.0.0.1:6878 (Ace Stream HTTP API)
vsock 6880     : host -> guest, connect to request a clean poweroff
```

### Why `/opt/bb`

At `init` time Rosetta binfmt_misc is not registered yet, so **no x86_64 binary
can be executed** — including `/bin/sh` of the amd64 Ubuntu userland. `/init`
therefore uses only the native aarch64 busybox and puts `/opt/bb` first on
`PATH`. The applet symlinks are generated in the arm64 build stage (the amd64
final stage could not run `busybox --install`).

### Rosetta registration

`init` mounts virtiofs tag `rosetta`, then writes to
`/proc/sys/fs/binfmt_misc/register` a `:rosetta:M::<20-byte magic>:<20-byte
mask>:/run/rosetta/rosetta:OCF` line matching ELF64/LE/`EM_X86_64`. The exact
byte sequence is asserted by `build-rootfs.sh` (hexdump of the same `printf`
under arm64 busybox). Failures are logged loudly and boot continues.

### Console markers

The macOS app can grep `hvc0` for:

* `KAKA-INIT: network up <ip>` — DHCP finished (or `none` on failure)
* `KAKA-INIT: engine loop starting` — engine supervision loop is about to run
* `KAKA-INIT: WARNING: ...` — non-fatal problems (Rosetta, DHCP, mounts)
* `KAKA-DHCP: ...` — udhcpc lease events

Engine output goes to the console **and** is appended to `/var/log/acestream.log`
(truncated on each boot).

## Rebuild

```sh
engine/build-rootfs.sh                 # full build + validation
engine/build-rootfs.sh --skip-validate # skip the 90 s HTTP API check
engine/build-rootfs.sh --skip-xz       # skip compression
IMG_SIZE=6G XZ_LEVEL=3 engine/build-rootfs.sh
```

The script starts OrbStack (`orbctl start`) if `docker info` fails.

## Notes / caveats

* **Engine flags.** `acestreamengine --help` for 3.2.11 does *not* list
  `--http-port`, `--bind-all`, `--cache-dir`, `--state-dir` or `--cache-limit`,
  but the engine parses them anyway (verified: it logs
  `state_dir='/var/lib/acestream'`). There is **no** `--live-cache-size`; the
  real option is `--live-mem-cache-size`, and `init` probes `--help` at boot and
  appends whichever of the two the binary advertises.
* **Python deps** are installed wheel-only (`--only-binary=:all:`) — no compiler
  in the image. Resolved versions are recorded at
  `/opt/acestream/installed-packages.txt` inside the image. Upstream floats
  (e.g. aiohttp 3.14 rather than the 3.9.5 wheel bundled in
  `/opt/acestream/lib`); pin in `requirements.txt` if that ever regresses.
* **DHCP.** `udhcpc` is started with `-f ... &` rather than `-b -q` so the lease
  keeps getting renewed while init stays non-blocking. busybox exports `$mask`
  as a prefix length, so `ip addr add $ip/$mask` is used directly.
* **Shutdown.** The Kata kernel is built without `CONFIG_MAGIC_SYSRQ`, so
  `/proc/sysrq-trigger` does not exist; `poweroff.sh` uses
  `busybox poweroff -f` after `sync` + `umount -a -r`. socat splits `EXEC:` on
  whitespace, which is why the handler is a script file rather than an inline
  `sh -c "..."`.
* `/etc/resolv.conf` is forced to a writable regular file (any symlink from the
  base image is removed) so `udhcpc.sh` can rewrite it.
* `socat` and the engine are amd64 and are only started **after** binfmt
  registration.
