# fox-builder

Reproducible, on-demand builder/installer for **Firefox (AVD)** on Asahi Linux
(Apple Silicon): builds Mozilla Firefox stable from source with the Asahi AVD
V4L2 RDD sandbox patch applied, using unofficial branding, and installs it as a
separate application named **Firefox (AVD)** — alongside, and without touching,
any distro-packaged Firefox.

The in-app updater is intentionally disabled: Firefox auto-update would
replace the patched build with stock Mozilla binaries. Re-running the script
*is* the update mechanism, on your schedule.

## Requirements

- Asahi Linux (aarch64) with a kernel that has the Apple AVD driver
  (`CONFIG_VIDEO_APPLE_AVD`), e.g. [maintaining-m1-linux/linux](https://github.com/maintaining-m1-linux/linux) `7.1.13-fairydust` or newer.
  Built-in (`=y`) AVD probes before the camera ISP module, so
  `/dev/media0` + `/dev/video0` belong to AVD — the paths hardcoded in the
  sandbox patch. If your numbering differs, adjust the paths in
  `patches/` before building.
- ~25 GB free disk (source + objdir), 8 GB RAM (swap is fine)
- `python3`, `curl`, `xz`, `patch`, ImageMagick (`convert`, only used to
  install the app icon — optional)
- C toolchain etc. is fetched automatically by `./mach bootstrap` into
  `~/.mozbuild` on first run

Debian/Ubuntu system packages:

```sh
sudo apt-get install -y --no-install-recommends \
    libgtk-3-dev libdbus-glib-1-dev libxt-dev libpulse-dev nasm unzip zip
```

Fedora:

```sh
sudo dnf install gtk3-devel dbus-glib-devel libXt-devel pulseaudio-libs-devel nasm unzip zip
```

## Usage

```sh
git clone https://github.com/maintaining-m1-linux/fox-builder.git
cd fox-builder
./installfox                # build + install latest stable (idempotent)
```

- `./installfox --force` — rebuild even if the same version is installed
- `./installfox --version X.Y.Z` — build a specific release
- `KEEP_WORKDIR=1 ./installfox` — keep the source/objdir (~20 GB) after success
- `PATCH=/path/to/patch` / `ICON=/path/to/icon.png` — override bundled resources

Installed layout, all inside `$HOME` (no root needed):

- Binary: `~/.local/opt/firefox-avd/` (version stamp: `.installfox-version`)
- Launcher: `~/.local/share/applications/firefox-avd.desktop` ("Firefox (AVD)")
- Icons: `~/.local/share/icons/hicolor/*/apps/firefox-avd.png`
- Profile: `~/.mozilla/firefox-avd` (separate from stock Firefox; first run
  creates it). Runs concurrently with distro Firefox via a dedicated
  `MOZ_APP_REMOTINGNAME`.

To update later: `git pull` (picks up script/patch/icon changes), then run
`./installfox` again.

## Files

- `installfox` — the whole build+install pipeline
- `patches/0001-firefox-153.3.0-asahi-rdd-request-v2.patch` — Asahi AVD V4L2
  RDD sandbox policy (grants the RDD process access to `/dev/media0`,
  `/dev/video0` and the media-controller ioctls needed for request-based
  hardware decoding)
- `assets/icon.png` — application icon (replace with your own; sized with
  ImageMagick at install time)

## Notes

- Unofficial branding is used; modified builds may not ship Mozilla's
  trademarks. Not affiliated with Mozilla. "Firefox" is a trademark of the
  Mozilla Foundation.
- Build logs: `~/build/installfox.log`; source tarballs are cached in
  `~/build/dl`.
