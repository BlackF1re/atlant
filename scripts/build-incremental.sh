#!/usr/bin/env bash
set -euo pipefail

TARGET=${1:-all}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. config/release.env

DIR=${RELEASE_DIR:-$ROOT/artifacts/current}
SD_IMAGE=${SD_IMAGE:-$DIR/${ATLANTIAN_IMAGE_NAME}.img}
COMPRESSED_IMAGE=${COMPRESSED_IMAGE:-$SD_IMAGE.xz}
BOOT_BIN=${BOOT_BIN:-$ROOT/out/bootloader/BOOT.bin}
UBOOT_IMG=${UBOOT_IMG:-$ROOT/out/bootloader/u-boot.img}
INITRAMFS=${INITRAMFS:-$ROOT/out/nand/initramfs.cpio.gz}

preflight() {
  bash "$ROOT/scripts/test-build-orchestration.sh"
  bash "$ROOT/scripts/test-runtime-policy.sh"
  bash "$ROOT/scripts/test-source-contracts.sh"
}

rootfs() {
  # Build Debian only once. Clone that common factory userspace for NAND before
  # either storage edition receives its runtime/storage-specific policy.
  sudo -E bash "$ROOT/scripts/build-rootfs.sh"
  sudo -E bash "$ROOT/scripts/build-nand-rootfs.sh"
  # Volatile APT state is a common runtime invariant. Install it only after the
  # factory package transactions are complete so build-chroot APT remains
  # independent of /run and SD/NAND receive byte-identical policy payloads.
  sudo bash "$ROOT/scripts/install-runtime-policy.sh" "$ROOT/out/rootfs"
  sudo bash "$ROOT/scripts/install-runtime-policy.sh" "$ROOT/out/rootfs-nand"
  sudo bash "$ROOT/scripts/install-nand-tools.sh" "$ROOT/out/rootfs" sd
  sudo bash "$ROOT/scripts/install-nand-tools.sh" "$ROOT/out/rootfs-nand" nand
}

kernel() {
  [[ -d $ROOT/out/rootfs && -d $ROOT/out/rootfs-nand ]] || rootfs
  sudo -E bash "$ROOT/scripts/build-kernel.sh"
  # These drivers/filesystems are needed before switch_root and therefore must
  # never silently become modules even if a future kernel changes dependencies.
  for opt in \
    CONFIG_MTD_NAND_PL35X CONFIG_MTD_NAND_ECC_SW_BCH CONFIG_MTD_UBI CONFIG_MTD_UBI_BLOCK \
    CONFIG_UBIFS_FS CONFIG_SQUASHFS CONFIG_SQUASHFS_ZSTD CONFIG_OVERLAY_FS CONFIG_EXT4_FS; do
    grep -qx "${opt}=y" "$ROOT/out/boot/kernel.config" || {
      echo "NAND early-root option is not built in: $opt" >&2; exit 3;
    }
  done
  sudo bash "$ROOT/scripts/strip-kernel-modules.sh" "$ROOT/out/rootfs"
  sudo rm -rf "$ROOT/out/rootfs-nand/lib/modules"
  sudo mkdir -p "$ROOT/out/rootfs-nand/lib/modules"
  sudo rsync -aHAX --numeric-ids "$ROOT/out/rootfs/lib/modules/" "$ROOT/out/rootfs-nand/lib/modules/"
}

stamp() {
  sudo -E bash "$ROOT/scripts/stamp-release.sh" "$ROOT/out/rootfs"
  sudo -E bash "$ROOT/scripts/stamp-release.sh" "$ROOT/out/rootfs-nand"
}

nand_initramfs() {
  [[ -d $ROOT/out/rootfs-nand ]] || rootfs
  ROOTFS="$ROOT/out/rootfs-nand" OUT="$INITRAMFS" bash "$ROOT/scripts/build-nand-initramfs.sh"
}

bootloader() {
  [[ -s $ROOT/out/boot/zImage && -s $ROOT/out/boot/devicetree.dtb ]] || kernel
  [[ -d $ROOT/out/rootfs && -d $ROOT/out/rootfs-nand ]] || rootfs

  # NAND U-Boot contains release-specific exact read lengths. Stamp first, build
  # one deterministic initramfs, then derive U-Boot from those exact bytes.
  stamp
  nand_initramfs
  bash "$ROOT/scripts/build-uboot.sh"
  INITRAMFS="$INITRAMFS" bash "$ROOT/scripts/build-uboot-nand.sh"
}

packages() { bash "$ROOT/scripts/build-atlantian-debs.sh"; }

nand_products() {
  [[ -s $INITRAMFS ]] || { echo "missing authoritative NAND initramfs: $INITRAMFS" >&2; exit 2; }
  INITRAMFS="$INITRAMFS" ROOTFS="$ROOT/out/rootfs-nand" bash "$ROOT/scripts/build-nand-bundle.sh"
}

embed_nand() {
  sudo env ROOTFS="$ROOT/out/rootfs" BUNDLE="$ROOT/out/nand/bundle" \
    bash "$ROOT/scripts/embed-nand-bundle.sh"
}

image() {
  mkdir -p "$DIR"
  rm -f "$DIR"/*.img "$DIR"/*.img.xz "$DIR"/*.deb "$DIR"/*.tar.zst "$DIR"/*.packages.tsv "$DIR"/*.snapshot.txt \
    "$DIR"/RELEASE-METADATA.json "$DIR"/SHA256SUMS
  [[ -d $ROOT/out/rootfs && -d $ROOT/out/rootfs-nand ]] || rootfs
  [[ -s $ROOT/out/boot/zImage && -s $ROOT/out/boot/devicetree.dtb ]] || kernel

  # Build the NAND payload before the SD image, then embed the exact checksummed
  # payload into the normal SD rootfs. The resulting image is both the ordinary
  # SD installation and the NAND installer/recovery medium.
  bootloader
  packages
  nand_products
  embed_nand

  sudo env ROOTFS="$ROOT/out/rootfs" BOOT_BIN="$BOOT_BIN" UBOOT_IMG="$UBOOT_IMG" \
    DTB="$ROOT/out/boot/devicetree.dtb" ZIMAGE="$ROOT/out/boot/zImage" \
    OUT="$SD_IMAGE" bash "$ROOT/scripts/make-sd-image.sh"

  bash "$ROOT/scripts/generate-release-metadata.sh" "$SD_IMAGE" "$DIR/RELEASE-METADATA.json" \
    "$ROOT/out/nand/bundle/NAND-MANIFEST.json"

  # Keep the raw image inside the sealed Actions artifact for layout/upgrade
  # validation, but publish the versioned XZ stream. Rufus, Raspberry Pi Imager
  # and Etcher can consume .xz images directly.
  echo "Compressing $(basename "$SD_IMAGE") -> $(basename "$COMPRESSED_IMAGE")"
  rm -f "$COMPRESSED_IMAGE" "$COMPRESSED_IMAGE.tmp"
  xz -T0 -6 --check=crc64 -c "$SD_IMAGE" >"$COMPRESSED_IMAGE.tmp"
  xz -t "$COMPRESSED_IMAGE.tmp"
  mv "$COMPRESSED_IMAGE.tmp" "$COMPRESSED_IMAGE"
  raw_sha=$(sha256sum "$SD_IMAGE" | awk '{print $1}')
  decoded_sha=$(xz -dc "$COMPRESSED_IMAGE" | sha256sum | awk '{print $1}')
  [[ "$decoded_sha" = "$raw_sha" ]] || {
    echo "compressed image round-trip checksum mismatch: $COMPRESSED_IMAGE" >&2
    exit 1
  }

  (cd "$DIR" && sha256sum *.img *.tar.zst *.deb RELEASE-METADATA.json >SHA256SUMS)
  (cd "$DIR" && sha256sum *.img.xz >>SHA256SUMS)
  sudo chown -R "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "$DIR"
}

full() { rootfs; kernel; image; }

if [[ ${ATLANTIAN_SKIP_PREFLIGHT:-0} != 1 ]]; then
  preflight
fi
case "$TARGET" in
  rootfs) rootfs ;;
  kernel) kernel ;;
  bootloader) bootloader ;;
  artifacts) image ;;
  image|rootfs-image|kernel-image|all) full ;;
  *) echo 'usage: build-incremental.sh {rootfs|kernel|bootloader|artifacts|image|rootfs-image|kernel-image|all}' >&2; exit 64 ;;
esac

echo "AtlANTian build completed: $TARGET"
