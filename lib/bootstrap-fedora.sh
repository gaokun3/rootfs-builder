#!/usr/bin/env bash
# Runs inside a fedora:<release> container. Creates the Fedora rootfs
# with dnf --installroot from the official repositories.
set -euo pipefail
# shellcheck disable=SC1091  # container path, checked separately
source /rb/lib/common.sh

profile="/rb/profiles/$DISTRO/$RELEASE"
MIRROR="official fedora repos (fedora + updates)"

dnf -y -q install zstd tar acl >/dev/null

dnf_install() {
  dnf -y --installroot="$ROOTFS" --releasever="$RELEASE" \
    --forcearch=aarch64 --use-host-config "${excludes[@]}" install "$@"
}

mapfile -t excludes_list < <(read_list "$profile/excludes.txt")
excludes=()
for e in "${excludes_list[@]}"; do excludes+=("--exclude=$e"); done

mapfile -t base_pkgs    < <(read_list "$profile/base.txt")
mapfile -t desktop_pkgs < <(read_list "$profile/$DESKTOP.txt")

# Display manager selection (KDE): prefer Plasma Login Manager when the
# official repos provide it with complete dependencies, else fall back
# to SDDM. GNOME always uses GDM.
DM=gdm
FIRST_BOOT=gnome-initial-setup
dm_pkgs=()
if [[ "$DESKTOP" == "kde" ]]; then
  FIRST_BOOT=tty-user-wizard
  if dnf -q --releasever="$RELEASE" --forcearch=aarch64 --use-host-config \
       repoquery plasma-login-manager kde-settings-plasmalogin 2>/dev/null |
     grep -q plasma-login-manager; then
    DM=plasma-login-manager
    dm_pkgs=(plasma-login-manager kde-settings-plasmalogin)
  else
    DM=sddm
    dm_pkgs=(sddm sddm-wayland-plasma)
  fi
  log "kde display manager: $DM"
fi

log "installing ${#base_pkgs[@]} base + ${#desktop_pkgs[@]} desktop entries"
dnf_install "${base_pkgs[@]}" "${desktop_pkgs[@]}" "${dm_pkgs[@]}"

# stub-resolv symlink: standard systemd-resolved layout on Fedora
ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"

pkg_installed() { rpm --root="$ROOTFS" -qa "$1" | grep -q .; }
write_package_inventory() {
  rpm --root="$ROOTFS" -qa --qf '%{NAME}\t%{EVR}\t%{ARCH}\n' | sort > "$1"
}

postprocess_rootfs "$DM" "$FIRST_BOOT"
verify_rootfs "$DM" "$profile/excludes.txt"
finalize_rootfs "$MIRROR" false \
  "fedora + updates repos are not snapshotted; exact versions in packages.txt"
