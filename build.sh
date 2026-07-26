#!/usr/bin/env bash
# Build a device-independent ARM64 minimal desktop rootfs.
#
#   ./build.sh --distro fedora --release 44 --desktop gnome
#
# The actual bootstrap runs inside the target distribution's official
# container image (docker). Output:
#   out/<distro>-<release>-<desktop>-minimal-aarch64-rootfs.tar.zst
#   out/<name>.manifest.json
#   out/<name>.packages.txt
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build.sh --distro <fedora|ubuntu|debian> --release <ver> --desktop <gnome|kde>
                [--output DIR] [--work DIR]

supported combinations:
  fedora  44            gnome|kde
  ubuntu  24.04.4       gnome|kde
  ubuntu  26.04         gnome|kde
  debian  trixie        gnome|kde
  debian  sid           gnome|kde

environment:
  ZSTD_LEVEL    zstd compression level (default 3)
  ZSTD_THREADS  zstd threads (default 0 = all cores)
EOF
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="" RELEASE="" DESKTOP=""
OUTPUT_DIR="$here/out"
WORK_DIR="$here/work"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --distro)  DISTRO="$2";  shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --desktop) DESKTOP="$2"; shift 2 ;;
    --output)  OUTPUT_DIR="$2"; shift 2 ;;
    --work)    WORK_DIR="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$DISTRO" && -n "$RELEASE" && -n "$DESKTOP" ]] || usage
[[ "$DESKTOP" == "gnome" || "$DESKTOP" == "kde" ]] || usage

# release -> codename / container image
CODENAME="" CONTAINER=""
case "$DISTRO/$RELEASE" in
  fedora/44)      CODENAME="44";       CONTAINER="fedora:44" ;;
  ubuntu/24.04.4) CODENAME="noble";    CONTAINER="ubuntu:24.04" ;;
  ubuntu/26.04)   CODENAME="resolute"; CONTAINER="ubuntu:26.04" ;;
  debian/trixie)  CODENAME="trixie";   CONTAINER="debian:trixie-slim" ;;
  debian/sid)     CODENAME="sid";      CONTAINER="debian:trixie-slim" ;;
  *) echo "error: unsupported combination $DISTRO $RELEASE" >&2; usage ;;
esac

profile="$here/profiles/$DISTRO/$RELEASE"
for f in base.txt "$DESKTOP.txt" excludes.txt; do
  [[ -f "$profile/$f" ]] || { echo "error: missing profile file $profile/$f" >&2; exit 1; }
done

name="$DISTRO-$RELEASE-$DESKTOP-minimal-aarch64-rootfs"
work="$WORK_DIR/$DISTRO-$RELEASE-$DESKTOP"
sudo rm -rf "$work"
mkdir -p "$work" "$OUTPUT_DIR"

ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
ZSTD_THREADS="${ZSTD_THREADS:-0}"

log() { printf '[rootfs-builder] %s\n' "$*"; }
log "building $name in $CONTAINER"

docker run --rm --privileged \
  -v "$here:/rb:ro" \
  -v "$work:/work" \
  -e DISTRO="$DISTRO" \
  -e RELEASE="$RELEASE" \
  -e CODENAME="$CODENAME" \
  -e DESKTOP="$DESKTOP" \
  -e ARTIFACT_NAME="$name" \
  -e ZSTD_LEVEL="$ZSTD_LEVEL" \
  -e ZSTD_THREADS="$ZSTD_THREADS" \
  "$CONTAINER" bash "/rb/lib/bootstrap-$DISTRO.sh"

# The container leaves: /work/$name.tar.zst, /work/build-info.env,
# /work/packages.txt
[[ -f "$work/$name.tar.zst" ]] || { echo "error: container produced no rootfs tarball" >&2; exit 1; }
# shellcheck source=/dev/null
source "$work/build-info.env"

cp "$work/packages.txt" "$OUTPUT_DIR/$name.packages.txt"
mv "$work/$name.tar.zst" "$OUTPUT_DIR/$name.tar.zst"

tarball="$OUTPUT_DIR/$name.tar.zst"
sha256="$(sha256sum "$tarball" | cut -d' ' -f1)"
compressed_size="$(stat -c%s "$tarball")"

cat > "$OUTPUT_DIR/$name.manifest.json" <<EOF
{
  "name": "$name",
  "distro": "$DISTRO",
  "release": "$RELEASE",
  "codename": "$CODENAME",
  "desktop": "$DESKTOP",
  "architecture": "aarch64",
  "container_image": "$CONTAINER",
  "mirror": "$BUILD_MIRROR",
  "display_manager": "$DISPLAY_MANAGER",
  "first_boot": "$FIRST_BOOT",
  "package_count": $PACKAGE_COUNT,
  "reproducible": $REPRODUCIBLE,
  "reproducibility_note": "$REPRODUCIBILITY_NOTE",
  "build_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "compression_format": "zstd",
  "compression_level": $ZSTD_LEVEL,
  "compression_threads": $ZSTD_THREADS,
  "uncompressed_size": $ROOTFS_BYTES,
  "compressed_size": $compressed_size,
  "sha256": "$sha256"
}
EOF
(cd "$OUTPUT_DIR" && sha256sum "$name.tar.zst" > "$name.tar.zst.sha256")

log "done: $tarball ($(du -h "$tarball" | cut -f1))"
log "      display manager: $DISPLAY_MANAGER, packages: $PACKAGE_COUNT"
