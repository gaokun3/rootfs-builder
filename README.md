# rootfs-builder

Builds device-independent ARM64 minimal desktop root filesystems for
the gaokun3 image pipeline. The rootfs contains **no** kernel, DTB,
device firmware, initrd, boot entries or fixed user accounts — those
are added by [image-builder](https://github.com/gaokun3/image-builder).

## Supported combinations

| distro | releases | desktops |
|---|---|---|
| Fedora | 44 | gnome, kde |
| Ubuntu | 24.04.4, 26.04 | gnome, kde |
| Debian | trixie, sid | gnome, kde |

## Usage

```sh
./build.sh --distro fedora --release 44 --desktop gnome
./build.sh --distro debian --release trixie --desktop kde
```

Requires docker (the bootstrap runs inside the target distro's official
container: `dnf --installroot` for Fedora, `debootstrap` for Ubuntu,
`mmdebstrap` for Debian).

Output in `out/`:

```text
<distro>-<release>-<desktop>-minimal-aarch64-rootfs.tar.zst
<name>.tar.zst.sha256
<name>.manifest.json     # inputs, display manager, sizes, sha256
<name>.packages.txt      # full package inventory with versions
```

## Package selection

Plain text lists under `profiles/<distro>/<release>/`:

- `base.txt` — minimal system
- `gnome.txt` / `kde.txt` — desktop set
- `excludes.txt` — packages that must not appear (dnf `--exclude` /
  apt pin -1); generic firmware is always excluded, the device image
  installs `gaokun3-firmware` instead

## Display manager

- GNOME → GDM.
- KDE → Plasma Login Manager **when the official repos of the target
  distro provide it**, otherwise SDDM. The choice is made by querying
  the repos at build time, recorded in the manifest, and verified
  (exactly one display manager enabled).

## First boot

No fixed user account is created. GNOME images use
`gnome-initial-setup`; KDE images include a minimal tty wizard
(`firstboot-user.service`) that creates the first user before the
display manager starts.

## Debian sid reproducibility

sid builds resolve packages live from `deb.debian.org` and are **not**
fully reproducible; the manifest says so explicitly and the exact
installed versions are recorded in `packages.txt`. Set
`DEBIAN_MIRROR=https://snapshot.debian.org/archive/debian/<TS>/` to
lock a snapshot for release builds.
