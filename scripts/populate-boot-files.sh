#!/usr/bin/env bash
# Populate the SD boot payload from the source-built bootloader + kernel assets.
# Image mode installs the complete boot chain and two kernel/DTB FIT slots;
# package mode carries only one candidate FIT plus the compatible loader/ABI.
set -euo pipefail

TARGET=${1:?usage: populate-boot-files.sh TARGET_DIR [image|package]}
MODE=${2:-image}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/config/release.env"

BOOT_BIN=${BOOT_BIN:-$ROOT/out/bootloader/BOOT.bin}
UBOOT_IMG=${UBOOT_IMG:-$ROOT/out/bootloader/u-boot.img}
DTB=${DTB:-$ROOT/out/boot/devicetree.dtb}
ZIMAGE=${ZIMAGE:-$ROOT/out/boot/zImage}
BOOT_ABI=1

case "$MODE" in image|package) ;; *) echo "invalid boot population mode: $MODE" >&2; exit 64;; esac
for f in "$DTB" "$ZIMAGE"; do
  [[ -s $f ]] || { echo "missing boot input: $f" >&2; exit 2; }
done
if [[ $MODE == image ]]; then
  for f in "$BOOT_BIN" "$UBOOT_IMG"; do
    [[ -s $f ]] || { echo "missing factory boot input: $f" >&2; exit 2; }
  done
fi
mkdir -p "$TARGET"
TARGET=$(readlink -f "$TARGET")

if [[ $MODE == image ]]; then
  install -m 0644 "$BOOT_BIN" "$TARGET/BOOT.bin"
  install -m 0644 "$UBOOT_IMG" "$TARGET/u-boot.img"
fi

# Kernel + DTB are one checksummed FIT object. The online updater therefore never
# exposes a mixed kernel/DTB generation: it writes the inactive FIT completely,
# syncs and verifies it, then switches one tiny FAT marker.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$ZIMAGE" "$tmp/kernel.bin"
cp "$DTB" "$tmp/board.dtb"
cat >"$tmp/atlantian.its" <<EOF_ITS
/dts-v1/;
/ {
  description = "AtlANTian ${ATLANTIAN_RELEASE_ID}";
  #address-cells = <1>;
  images {
    kernel-1 {
      description = "AtlANTian Linux ${ATLANTIAN_KERNEL_VERSION}";
      data = /incbin/("kernel.bin");
      type = "kernel";
      arch = "arm";
      os = "linux";
      compression = "none";
      load = <0x00008000>;
      entry = <0x00008000>;
      hash-1 { algo = "sha256"; };
    };
    fdt-1 {
      description = "Antminer S9 device tree";
      data = /incbin/("board.dtb");
      type = "flat_dt";
      arch = "arm";
      compression = "none";
      hash-1 { algo = "sha256"; };
    };
  };
  configurations {
    default = "conf-1";
    conf-1 {
      description = "AtlANTian SD boot";
      kernel = "kernel-1";
      fdt = "fdt-1";
    };
  };
};
EOF_ITS
(cd "$tmp" && mkimage -f atlantian.its "$TARGET/atlantian.itb" >/dev/null)
mkimage -l "$TARGET/atlantian.itb" >/dev/null

if [[ $MODE == image ]]; then
  mv "$TARGET/atlantian.itb" "$TARGET/atlantian-A.itb"
  cp "$TARGET/atlantian-A.itb" "$TARGET/atlantian-B.itb"
  rm -f "$TARGET/atlantian-slot-B"
fi
printf '%s\n' "$BOOT_ABI" >"$TARGET/atlantian-boot-abi"

# uEnv.txt is a factory-image rescue/reference environment. Normal autoboot
# executes boot.scr directly from the immutable SPL/U-Boot chain; update packages
# do not carry or rewrite this file.
if [[ $MODE == image ]]; then
  cat >"$TARGET/uEnv.txt" <<'EOF_UENV'
atlantian_normal_bootargs=console=ttyPS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait
atlantian_fit=atlantian-A.itb
bootcmd=setenv bootargs ${atlantian_normal_bootargs}; fatload mmc 0:1 0x02000000 ${atlantian_fit} && bootm 0x02000000
EOF_UENV
fi

cmd="$tmp/boot.cmd"
cat >"$cmd" <<'EOF_BOOT'
echo Booting AtlANTian from microSD...
# The NAND installer may place a one-shot, checksummed U-Boot script on this FAT
# partition. It programs only the raw NAND boot region while the physical jumper
# still selects SD. A different RAM address keeps the executing parent boot.scr
# intact. Normal cards have no stage file and follow the ordinary path below.
if test -e mmc 0:1 atln-stage.scr; then
    echo AtlANTian NAND installer stage detected.
    if fatload mmc 0:1 0x06000000 atln-stage.scr; then
        source 0x06000000
    fi
fi

setenv atlantian_fit atlantian-A.itb
setenv atlantian_fallback atlantian-B.itb
if test -e mmc 0:1 atlantian-slot-B; then
    setenv atlantian_fit atlantian-B.itb
    setenv atlantian_fallback atlantian-A.itb
fi
setenv bootargs console=ttyPS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait
if fatload mmc 0:1 0x02000000 ${atlantian_fit}; then
    bootm 0x02000000
fi
echo AtlANTian active FIT failed; trying rollback slot...
if fatload mmc 0:1 0x02000000 ${atlantian_fallback}; then
    bootm 0x02000000
fi

# This path exists only for the one-time migration from releases that predate
# transactional FIT slots. The package postinst installs both FIT slots before
# replacing boot.scr, so power loss cannot make the legacy generation disappear.
echo AtlANTian FIT slots failed; trying legacy migration payload...
if fatload mmc 0:1 0x02000000 uImage && fatload mmc 0:1 0x01F00000 devicetree.dtb; then
    bootm 0x02000000 - 0x01F00000
fi
echo AtlANTian boot failed; returning to U-Boot
EOF_BOOT
mkimage -A arm -T script -C none -n 'AtlANTian microSD transactional boot' -d "$cmd" "$TARGET/boot.scr" >/dev/null

# There must never be a Linux-side fixed RAM cap. DDR size is detected by the
# Antminer S9 U-Boot target on every cold boot and then fixed into the Linux DT.
if [[ $MODE == image ]]; then
  ! grep -Eq '(^|[[:space:]])mem=[^[:space:]]+' "$TARGET/uEnv.txt"
fi
! strings "$TARGET/boot.scr" | grep -Eq '(^|[[:space:]])mem=[^[:space:]]+'
