#!/usr/bin/env bash
# Assemble the factory SD image. This script never writes a physical disk.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJECT/config/release.env"
. "$PROJECT/config/image-layout.env"
ROOTFS=${ROOTFS:-$PROJECT/out/rootfs}
OUT=${OUT:-$PROJECT/out/${ATLANTIAN_IMAGE_NAME}.img}
BOOT_BIN=${BOOT_BIN:?set BOOT_BIN}
UBOOT_IMG=${UBOOT_IMG:?set UBOOT_IMG}
DTB=${DTB:?set DTB}
ZIMAGE=${ZIMAGE:?set ZIMAGE}
for f in "$BOOT_BIN" "$UBOOT_IMG" "$DTB" "$ZIMAGE"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }; done
[ -d "$ROOTFS" ] || { echo "missing ROOTFS" >&2; exit 2; }
# `du` cannot account precisely for ext4 metadata, inode tables and xattrs.
# Start compactly, then retry only ENOSPC with a slightly larger disposable
# filesystem. The completed p2 is later grown to the entire SD card on first boot.
root_mib=$(du -sm --apparent-size "$ROOTFS" | awk '{print $1}')
root_mib=$((root_mib + ATLANTIAN_INITIAL_ROOT_SLACK_MIB))
LOOP= BOOT= ROOT=
cleanup(){ set +e; [ -n "${ROOT:-}" ] && mountpoint -q "$ROOT" && umount "$ROOT"; [ -n "${BOOT:-}" ] && mountpoint -q "$BOOT" && umount "$BOOT"; [ -n "${ROOT:-}" ] && rmdir "$ROOT"; [ -n "${BOOT:-}" ] && rmdir "$BOOT"; [ -n "${LOOP:-}" ] && losetup -d "$LOOP"; }
trap cleanup EXIT
while :; do
  size_mib=$((1 + ATLANTIAN_BOOT_MIB + root_mib))
  mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"; truncate -s "${size_mib}M" "$OUT"
  parted -s "$OUT" mklabel msdos
  parted -s "$OUT" mkpart primary fat32 1MiB "$((1 + ATLANTIAN_BOOT_MIB))MiB"
  parted -s "$OUT" set 1 boot on
  parted -s "$OUT" mkpart primary ext4 "$((1 + ATLANTIAN_BOOT_MIB))MiB" 100%
  LOOP=$(losetup --find --show --partscan "$OUT")
  mkfs.vfat -F 32 -n BOOT "${LOOP}p1"
  mkfs.ext4 -F -m 0 -L atlantian-root "${LOOP}p2"
  BOOT=$(mktemp -d /mnt/atlantian-boot.XXXXXX); ROOT=$(mktemp -d /mnt/atlantian-root.XXXXXX)
  mount "${LOOP}p1" "$BOOT"; mount "${LOOP}p2" "$ROOT"
  if rsync -aHAX --numeric-ids "$ROOTFS/" "$ROOT/"; then
    break
  else
    rsync_status=$?
  fi
  cleanup; LOOP= BOOT= ROOT=
  [ "$rsync_status" -eq 11 ] || exit "$rsync_status"
  root_mib=$((root_mib + 32))
  echo "rootfs did not fit; retrying image with p2=${root_mib} MiB" >&2
done

BOOT_BIN="$BOOT_BIN" UBOOT_IMG="$UBOOT_IMG" DTB="$DTB" ZIMAGE="$ZIMAGE" \
  "$PROJECT/scripts/populate-boot-files.sh" "$BOOT"
sync
cp "$ROOTFS/usr/share/atlantian/debian-package-manifest.tsv" "${OUT%.img}.packages.tsv"
cp "$ROOTFS/usr/share/atlantian/debian-snapshot.txt" "${OUT%.img}.snapshot.txt"
echo "Created factory image: $OUT"
