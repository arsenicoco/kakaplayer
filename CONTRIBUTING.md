# Contributing to KakaPlayer

Thanks for taking a look! This is a personal hobby project, but issues and pull
requests are welcome.

## Building

You need an Apple Silicon Mac on macOS 26+ with Xcode 26+. See the
[Build from source](README.md#build-from-source) section of the README. In
short:

```bash
brew install xcodegen
scripts/bootstrap.sh     # fetches VLCKit, the guest kernel, gvproxy; builds the engine image
scripts/build-app.sh     # produces dist/KakaPlayer.app and dist/KakaPlayer.dmg
```

Only the engine-image step needs Docker (OrbStack or Docker Desktop), and only
at build time. The finished app needs nothing but macOS.

## Project layout

- `app/` — the Swift/SwiftUI application (`project.yml` drives XcodeGen).
- `engine/` — the Linux guest: Dockerfile, `init`, and `build-rootfs.sh`.
- `scripts/` — fetch/build/release helpers.

## Pull requests

- Keep changes focused and describe what you tested.
- The app is ad-hoc signed; there's no CI build (the guest image needs Docker),
  so please note how you verified your change locally.
- By contributing you agree your contribution is MIT-licensed.
