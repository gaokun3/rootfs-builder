#!/usr/bin/env bash
# Shared in-container helpers, sourced by lib/bootstrap-<distro>.sh.
# Everything here operates on the rootfs at $ROOTFS and expects to run
# as root inside the target distro's container.

ROOTFS=/work/rootfs

log() { printf '[%s] %s\n' "${DISTRO:-rootfs}" "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# Read a profile package list: strips comments and blank lines.
read_list() {
  grep -vE '^\s*(#|$)' "$1" || true
}

in_chroot() {
  chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive "$@"
}

# Pick the first systemd unit (basename, no suffix) that exists in the
# rootfs from the given candidates. Echoes the unit name, empty if none.
find_unit() {
  local u
  for u in "$@"; do
    if [[ -f "$ROOTFS/usr/lib/systemd/system/$u.service" ||
          -f "$ROOTFS/lib/systemd/system/$u.service" ]]; then
      echo "$u"
      return 0
    fi
  done
  return 1
}

# install_firstboot_wizard: minimal tty user-creation wizard for KDE
# images (GNOME uses gnome-initial-setup instead). Installed files are
# distro-neutral; the admin group is detected at runtime.
install_firstboot_wizard() {
  install -Dm755 /rb/lib/firstboot-user.sh \
    "$ROOTFS/usr/lib/firstboot-user/firstboot-user.sh"
  install -Dm644 /rb/lib/firstboot-user.service \
    "$ROOTFS/usr/lib/systemd/system/firstboot-user.service"
  in_chroot systemctl enable firstboot-user.service
}

# postprocess_rootfs <display-manager-unit> <first-boot-mechanism>
postprocess_rootfs() {
  local dm="$1" firstboot="$2"

  log "postprocess: display manager '$dm', first boot '$firstboot'"

  in_chroot systemctl enable NetworkManager.service
  in_chroot systemctl set-default graphical.target
  # policy-rc.d (Debian/Ubuntu) blocks postinst-driven enablement, so this
  # has to be explicit rather than relying on the package's own preset
  local ssh_unit
  ssh_unit="$(find_unit ssh sshd)" || die "no ssh/sshd unit found (openssh-server missing from base.txt?)"
  in_chroot systemctl enable "$ssh_unit.service"
  # deterministic single display manager
  in_chroot systemctl enable "$dm.service"
  local unit_dir=/usr/lib/systemd/system
  [[ -f "$ROOTFS/usr/lib/systemd/system/$dm.service" ]] || unit_dir=/lib/systemd/system
  ln -sf "$unit_dir/$dm.service" "$ROOTFS/etc/systemd/system/display-manager.service"

  if [[ "$firstboot" == "tty-user-wizard" ]]; then
    install_firstboot_wizard
  fi

  # cleanup
  rm -rf "$ROOTFS"/var/cache/dnf/* "$ROOTFS"/var/cache/libdnf5/* \
         "$ROOTFS"/var/cache/apt/archives "$ROOTFS"/var/lib/apt/lists \
         "$ROOTFS"/var/tmp/* "$ROOTFS"/tmp/* 2>/dev/null || true
  find "$ROOTFS/var/log" -type f -delete 2>/dev/null || true
  rm -f "$ROOTFS/root/.bash_history" \
        "$ROOTFS/var/lib/systemd/random-seed" \
        "$ROOTFS/var/lib/dbus/machine-id"
  : > "$ROOTFS/etc/machine-id"
}

# verify_rootfs <display-manager-unit> <excludes-file>
# Static verification; any violation fails the build.
verify_rootfs() {
  local dm="$1" excludes_file="$2" fail=0

  # exactly one display manager
  local target
  target="$(readlink "$ROOTFS/etc/systemd/system/display-manager.service" || true)"
  if [[ "$target" != *"/$dm.service" ]]; then
    echo "verify: FAIL: display-manager.service -> '$target', expected $dm" >&2; fail=1
  else
    log "verify: ok: display-manager -> $dm"
  fi
  local other
  for other in gdm gdm3 sddm plasmalogin plasma-login-manager lightdm; do
    [[ "$other" == "$dm" ]] && continue
    if [[ "$(in_chroot systemctl is-enabled "$other.service" 2>/dev/null || true)" == "enabled" ]]; then
      echo "verify: FAIL: second display manager enabled: $other" >&2; fail=1
    fi
  done

  # NetworkManager + graphical.target
  if [[ "$(in_chroot systemctl is-enabled NetworkManager.service 2>/dev/null)" == "enabled" ]]; then
    log "verify: ok: NetworkManager enabled"
  else
    echo "verify: FAIL: NetworkManager not enabled" >&2; fail=1
  fi
  local deftarget
  deftarget="$(readlink "$ROOTFS/etc/systemd/system/default.target" || true)"
  if [[ "$deftarget" == *graphical.target ]]; then
    log "verify: ok: default target graphical"
  else
    echo "verify: FAIL: default.target -> '$deftarget'" >&2; fail=1
  fi

  # ssh/sshd enabled (remote access on every image)
  local ssh_unit
  if ssh_unit="$(find_unit ssh sshd)" &&
     [[ "$(in_chroot systemctl is-enabled "$ssh_unit.service" 2>/dev/null)" == "enabled" ]]; then
    log "verify: ok: $ssh_unit enabled"
  else
    echo "verify: FAIL: ssh/sshd not enabled" >&2; fail=1
  fi

  # machine-id cleared
  if [[ -s "$ROOTFS/etc/machine-id" ]]; then
    echo "verify: FAIL: /etc/machine-id not empty" >&2; fail=1
  else
    log "verify: ok: machine-id cleared"
  fi

  # excluded packages absent
  local pat excl_fail=0
  while IFS= read -r pat; do
    if pkg_installed "$pat"; then
      echo "verify: FAIL: excluded package present: $pat" >&2; fail=1; excl_fail=1
    fi
  done < <(read_list "$excludes_file")
  if [[ $excl_fail -eq 0 ]]; then log "verify: ok: excluded packages absent"; fi

  # no device kernel / initrd in a generic rootfs (other stray files are
  # reported but tolerated)
  local kfiles ofiles
  kfiles="$(find "$ROOTFS/boot" -type f \( -name 'vmlinuz*' -o -name 'initrd*' \
    -o -name 'initramfs*' -o -name 'Image*' -o -name 'System.map*' -o -name '*.dtb' \) 2>/dev/null)"
  if [[ -n "$kfiles" ]]; then
    echo "verify: FAIL: kernel artifacts in /boot: $kfiles" >&2; fail=1
  fi
  ofiles="$(find "$ROOTFS/boot" -type f 2>/dev/null | head -5)"
  if [[ -n "$ofiles" ]]; then log "note: non-kernel files in /boot: $(echo "$ofiles" | tr '\n' ' ')"; fi

  [[ $fail -eq 0 ]] || die "rootfs verification failed"
  log "verify: rootfs OK"
}

# write inventory + tarball + build-info.env
finalize_rootfs() {
  local mirror="$1" reproducible="$2" note="$3"

  write_package_inventory /work/packages.txt
  local count rootfs_bytes
  count="$(wc -l < /work/packages.txt)"
  rootfs_bytes="$(du -sb "$ROOTFS" | cut -f1)"

  log "packing $ARTIFACT_NAME.tar.zst (zstd -$ZSTD_LEVEL -T$ZSTD_THREADS)"
  tar --xattrs --acls --numeric-owner -C "$ROOTFS" -cf - . |
    zstd "-$ZSTD_LEVEL" "-T$ZSTD_THREADS" -q -f -o "/work/$ARTIFACT_NAME.tar.zst"
  chmod 644 "/work/$ARTIFACT_NAME.tar.zst"

  cat > /work/build-info.env <<EOF
DISPLAY_MANAGER="$DM"
FIRST_BOOT="$FIRST_BOOT"
BUILD_MIRROR="$mirror"
PACKAGE_COUNT=$count
ROOTFS_BYTES=$rootfs_bytes
REPRODUCIBLE=$reproducible
REPRODUCIBILITY_NOTE="$note"
EOF
  log "rootfs finished: $count packages, $rootfs_bytes bytes uncompressed"
}
