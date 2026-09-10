<div align="center">

<img src="docs/icon.png" width="120" alt="KakaPlayer icon">

# KakaPlayer

**A single-app Ace Stream player for Apple Silicon Macs.**
Open an `acestream://` link and it plays. No Docker, no VLC, no extra installs.

[![Download](https://img.shields.io/github/v/release/arsenicoco/kakaplayer?label=Download%20DMG&style=for-the-badge)](https://github.com/arsenicoco/kakaplayer/releases/latest)
&nbsp;
![Platform](https://img.shields.io/badge/macOS%2026%2B-Apple%20Silicon-black?style=for-the-badge)
&nbsp;
![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)

<img src="docs/screenshots/playing.png" width="820" alt="KakaPlayer playing a stream">

</div>

---

## Why

There has never been a macOS build of the Ace Stream engine — it only exists for
Windows, Linux (x86_64) and Android. Every previous way to watch `acestream://`
links on a Mac meant running the engine in Docker or a Linux VM and pointing VLC
at it by hand. KakaPlayer bundles all of that inside one `.app` so you never see
it.

<div align="center">
<img src="docs/screenshots/idle.png" width="640" alt="KakaPlayer idle screen">
</div>

## Install

1. Download `KakaPlayer.dmg` from the [latest release](https://github.com/arsenicoco/kakaplayer/releases/latest).
2. Open it and drag **KakaPlayer** to Applications.
3. First launch: the app isn't notarized, so right-click it → **Open** → **Open**
   (or run `xattr -dr com.apple.quarantine /Applications/KakaPlayer.app`).

The first launch unpacks the engine image (~1 GB on disk) and boots the VM, so
the first channel takes 20–40 seconds. Later launches are fast.

**Requirements:** Apple Silicon Mac on macOS 26 or later.

## Use

- Paste an `acestream://…` link (or a 40-character content ID) and press **Play**.
- Or click any `acestream://` link anywhere — it opens in KakaPlayer.
- During playback the controls fade out when the mouse is idle and return on
  movement; double-click the video (or the ⤢ button) for full screen.

## How it works

```
KakaPlayer.app
├── VLCKit.framework      plays the MPEG-TS stream (H.264/HEVC, AAC/MP2/AC-3, …)
├── gvproxy               user-space networking for the guest
├── vmlinux-arm64         minimal Linux kernel (Kata Containers build)
└── rootfs.img.xz         Ubuntu 22.04 + the official Ace Stream engine 3.2.11
```

1. A tiny Linux VM boots on Apple's **Virtualization.framework**, with **Rosetta**
   shared in so the x86_64 engine runs on Apple Silicon.
2. The guest exposes the engine's HTTP API to the Mac over **vsock**, so it looks
   exactly like a local Ace Stream install on `127.0.0.1:6878`.
3. A small in-app relay holds a single connection to the engine and fans the
   stream out to the embedded **VLCKit** player.

More detail lives in [`engine/README.md`](engine/README.md).

## Build from source

You need an Apple Silicon Mac on macOS 26+ with Xcode 26+, plus
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for the engine image only,
Docker (OrbStack or Docker Desktop).

```bash
brew install xcodegen
scripts/bootstrap.sh     # fetch VLCKit, the guest kernel, gvproxy; build the engine image
scripts/build-app.sh     # -> dist/KakaPlayer.app and dist/KakaPlayer.dmg
open dist/KakaPlayer.app
```

`bootstrap.sh` pulls every third-party component straight from its upstream, so
nothing proprietary is stored in this repo. Only the engine-image step needs
Docker, and only at build time.

To cut a release (builds and publishes the DMG to GitHub):

```bash
scripts/release.sh v0.1.0 "First public build"
```

### Reclaiming disk space

Everything the build produces or fetches is disposable and reproducible, so you
can delete it any time to free space:

- `build/` — Xcode DerivedData, the VLCKit download, the guest kernel, and the
  engine image (several GB).
- `dist/` — the built `.app` and `.dmg` (the DMG also lives on the
  [Releases](https://github.com/arsenicoco/kakaplayer/releases) page).
- The fetched bundle resources under `app/Packages/VLCKitBinary/` and
  `app/KakaPlayer/Resources/` (all gitignored).

```bash
rm -rf build dist        # safe: nothing here is source
```

To rebuild afterwards, run **`scripts/bootstrap.sh` first** — it re-fetches every
third-party component from upstream (VLCKit ≈ 900 MB, the Kata kernel, gvproxy)
and rebuilds the engine image, then `scripts/build-app.sh` produces the app
again:

```bash
scripts/bootstrap.sh     # re-creates build/ and the bundle resources
scripts/build-app.sh     # -> dist/KakaPlayer.app and dist/KakaPlayer.dmg
```

`bootstrap.sh` is idempotent: it skips any component that's already present, so
it's safe to re-run after a partial cleanup. The engine-image step needs Docker
(OrbStack or Docker Desktop) running.

## Credits

KakaPlayer stands on:

- [VLCKit](https://code.videolan.org/videolan/VLCKit) — playback
- [Ace Stream](https://acestream.org) — the P2P streaming engine
- [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock) — guest networking
- [Kata Containers](https://github.com/kata-containers/kata-containers) — the guest kernel
- Apple's Virtualization.framework and Rosetta

Full licenses and sources are in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

KakaPlayer's own code is [MIT](LICENSE). The packaged app bundles third-party
components under their own licenses — see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Disclaimer

KakaPlayer is an independent client for the Ace Stream engine. It is not
affiliated with or endorsed by Ace Stream, VideoLAN, or Apple. It ships **no**
content, channel lists, or links, and it does not host or index any streams —
it only plays a link you provide. You are responsible for the content you access
and for complying with the Ace Stream User Agreement and the laws of your
country. Some Ace Stream content may require an Ace Stream Premium account.
