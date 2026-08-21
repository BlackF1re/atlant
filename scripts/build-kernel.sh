#!/usr/bin/env bash
# Build the board kernel and install only its modules into the Debian rootfs.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJECT/config/release.env"
SRC=${SRC:-$PROJECT/out/linux-src}
ROOTFS=${ROOTFS:-$PROJECT/out/rootfs}
OUT=${OUT:-$PROJECT/out/boot}
BOARD_DTS=${BOARD_DTS:-$PROJECT/board/zynq-bitmain-antminer-s9.dts}
FRAGMENT=${FRAGMENT:-$PROJECT/config/kernel.fragment}
PRUNE_FRAGMENT=${PRUNE_FRAGMENT:-$PROJECT/config/kernel-prune.fragment}
OF_CONFIGFS_SOURCE=${OF_CONFIGFS_SOURCE:-$PROJECT/kernel-overlay/of-configfs.c}
JOBS=${JOBS:-$(nproc)}
TARGET=${1:-all}
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}

case "$TARGET" in
  all|dtb|config) ;;
  *) echo "usage: $0 [all|dtb|config]" >&2; exit 64 ;;
esac
[[ -f "$BOARD_DTS" && -f "$FRAGMENT" && -f "$PRUNE_FRAGMENT" ]] || {
  echo 'missing board DTS or kernel fragments' >&2; exit 2;
}

# This is the single source-preparation path for local and CI builds. It fetches
# only the configured immutable commit and verifies that the source itself
# reports the configured Linux version. A tag is metadata, never a source pin.
bash "$PROJECT/scripts/prepare-kernel-source.sh" "$SRC"
[[ -d "$SRC/.git" ]] || { echo "missing prepared Linux source: $SRC" >&2; exit 2; }

cd "$SRC"
actual_commit=$(git -c safe.directory="$SRC" rev-parse HEAD)
[[ $actual_commit == "$ATLANTIAN_KERNEL_COMMIT" ]] || {
  echo "Linux source moved after preparation: expected $ATLANTIAN_KERNEL_COMMIT, got $actual_commit" >&2
  exit 2
}

# Mainline 6.12 contains the OF overlay core but no userspace attachment API.
# Vendor the small, source-audited configfs frontend used by Raspberry Pi
# Linux. This keeps the stable kernel base while making FPGA Region profiles
# dynamically attachable and removable from standard userspace.
[[ -f "$OF_CONFIGFS_SOURCE" ]] || { echo "missing $OF_CONFIGFS_SOURCE" >&2; exit 2; }
install -m 0644 "$OF_CONFIGFS_SOURCE" drivers/of/configfs.c

grep -q '^config OF_CONFIGFS$' drivers/of/Kconfig || sed -i '/^endif # OF$/i\config OF_CONFIGFS\n\tbool "Device Tree Overlay ConfigFS interface"\n\tselect CONFIGFS_FS\n\tselect OF_OVERLAY\n\thelp\n\t  Enable a userspace-driven Device Tree overlay interface.\n' drivers/of/Kconfig
grep -q 'CONFIG_OF_CONFIGFS.*configfs.o' drivers/of/Makefile || \
  sed -i '/obj-$(CONFIG_OF_KOBJ) += kobj.o/a obj-$(CONFIG_OF_CONFIGFS) += configfs.o' drivers/of/Makefile

# The upstream PL35X NAND driver forces NAND_BBT_USE_FLASH for every attached
# chip. That makes a mere Linux probe create mirrored BBT records at the end of
# an otherwise untouched factory NAND when no flash BBT is present. The generic
# raw-NAND core already implements the standard `nand-on-flash-bbt` DT property:
# without it, factory bad-block markers are scanned into a volatile RAM table and
# probing is read-only. AtlANTian intentionally omits that DT property, so remove
# the controller driver's unconditional override.
#
# Keep this transform idempotent because a cached Linux tree may already contain
# the AtlANTian edit from an earlier build on the same runner/cache.
python3 - <<'PY'
from pathlib import Path

path = Path('drivers/mtd/nand/raw/pl35x-nand-controller.c')
text = path.read_text()
needle = '\tchip->bbt_options = NAND_BBT_USE_FLASH;\n'
marker = '\t/* AtlANTian: honor the generic nand-on-flash-bbt DT policy. */\n'
if needle in text:
    if text.count(needle) != 1:
        raise SystemExit('unexpected number of PL35X forced flash-BBT assignments')
    text = text.replace(needle, marker)
    path.write_text(text)
elif marker not in text:
    raise SystemExit('PL35X source no longer matches the read-only NAND probe transform')
PY
grep -Fq 'AtlANTian: honor the generic nand-on-flash-bbt DT policy.' \
  drivers/mtd/nand/raw/pl35x-nand-controller.c
! grep -Fq 'chip->bbt_options = NAND_BBT_USE_FLASH;' \
  drivers/mtd/nand/raw/pl35x-nand-controller.c

DTS_DIR=$SRC/arch/arm/boot/dts/xilinx
cp "$BOARD_DTS" "$DTS_DIR/zynq-bitmain-antminer-s9.dts"
grep -q '^DTC_FLAGS_zynq-bitmain-antminer-s9.*-@' "$DTS_DIR/Makefile" ||
  printf '\nDTC_FLAGS_zynq-bitmain-antminer-s9 += -@\n' >>"$DTS_DIR/Makefile"
grep -q 'zynq-bitmain-antminer-s9.dtb' "$DTS_DIR/Makefile" ||
  printf 'dtb-$(CONFIG_ARCH_ZYNQ) += zynq-bitmain-antminer-s9.dtb\n' >>"$DTS_DIR/Makefile"

make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" multi_v7_defconfig
scripts/kconfig/merge_config.sh -m .config "$PRUNE_FRAGMENT" "$FRAGMENT"
# A released kernel must not inherit the source tree state. In particular,
# CONFIG_LOCALVERSION_AUTO would append -g<hash>-dirty to uname -r.
sed -i '/^CONFIG_LOCALVERSION=/d;/^CONFIG_LOCALVERSION_AUTO=/d' .config
printf 'CONFIG_LOCALVERSION="%s"\nCONFIG_LOCALVERSION_AUTO=n\n' "$ATLANTIAN_KERNEL_LOCALVERSION" >>.config
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

for opt in \
  CONFIG_EXT4_FS CONFIG_MMC CONFIG_MMC_BLOCK CONFIG_MMC_SDHCI \
  CONFIG_MMC_SDHCI_PLTFM CONFIG_MMC_SDHCI_OF_ARASAN CONFIG_MACB \
  CONFIG_PHYLIB CONFIG_BROADCOM_PHY CONFIG_ARCH_ZYNQ CONFIG_HIGHMEM \
  CONFIG_WATCHDOG CONFIG_WATCHDOG_SYSFS CONFIG_CADENCE_WATCHDOG; do
  grep -qx "${opt}=y" .config || { echo "required boot option missing: $opt" >&2; exit 3; }
done
# Watchdog availability is deliberate, but activation remains a userspace
# policy. Keep the watchdog stoppable after an explicit open/start rather than
# compiling a global nowayout policy into every AtlANTian installation.
grep -Fqx '# CONFIG_WATCHDOG_NOWAYOUT is not set' .config || {
  echo 'watchdog must remain optional/stoppable (CONFIG_WATCHDOG_NOWAYOUT=n)' >&2
  exit 3
}
# A release must never silently regress to the enormous universal ARM kernel.
# These devices cannot be connected to the target PS or PL fabric. Future USB
# and FPGA profiles remain covered by the positive checks above.
for opt in \
  CONFIG_PCI CONFIG_WLAN CONFIG_CFG80211 CONFIG_MAC80211 CONFIG_BT CONFIG_NFC CONFIG_ATA \
  CONFIG_ARCH_BCM CONFIG_ARCH_EXYNOS CONFIG_ARCH_MXC CONFIG_ARCH_OMAP2PLUS \
  CONFIG_ARCH_QCOM CONFIG_ARCH_ROCKCHIP CONFIG_ARCH_RENESAS \
  CONFIG_ARCH_SUNXI CONFIG_ARCH_TEGRA CONFIG_ARCH_WM8850 \
  CONFIG_DRM_NOUVEAU CONFIG_DRM_MSM CONFIG_DRM_VC4 CONFIG_DRM_V3D \
  CONFIG_DRM_LIMA CONFIG_DRM_PANFROST CONFIG_DRM_ATMEL_HLCDC \
  CONFIG_DRM_FSL_DCU CONFIG_DRM_PL111 \
  CONFIG_BCMGENET CONFIG_SYSTEMPORT CONFIG_FTGMAC100 \
  CONFIG_LAN966X_SWITCH CONFIG_USB_MUSB_HDRC \
  CONFIG_MEDIA_ANALOG_TV_SUPPORT CONFIG_MEDIA_DIGITAL_TV_SUPPORT \
  CONFIG_MEDIA_RADIO_SUPPORT CONFIG_MEDIA_TEST_SUPPORT \
  CONFIG_MEDIA_USB_SUPPORT; do
  grep -Eq "^${opt}=(y|m)$" .config && {
    echo "forbidden target-hardware option enabled: $opt" >&2
    exit 3
  }
done
# Prevent a dependency change in a future stable kernel from silently removing
# an advertised board or PL-profile ABI. These may be resident or modular,
# but they must exist in the released kernel and its module set.
for opt in \
  CONFIG_FPGA_MGR_ZYNQ_FPGA CONFIG_FPGA_REGION CONFIG_OF_FPGA_REGION \
  CONFIG_OF_OVERLAY CONFIG_OF_CONFIGFS CONFIG_GPIO_ZYNQ CONFIG_LEDS_GPIO \
  CONFIG_INPUT_EVDEV CONFIG_KEYBOARD_GPIO \
  CONFIG_SERIAL_XILINX_PS_UART CONFIG_MTD_NAND_PL35X \
  CONFIG_MTD_NAND_ECC_SW_BCH CONFIG_MTD_UBI CONFIG_UBIFS_FS \
  CONFIG_IIO CONFIG_XILINX_XADC CONFIG_SENSORS_IIO_HWMON \
  CONFIG_CADENCE_WATCHDOG CONFIG_GPIO_XILINX CONFIG_I2C_CADENCE \
  CONFIG_I2C_XILINX CONFIG_SPI_CADENCE CONFIG_SPI_XILINX \
  CONFIG_USB_CHIPIDEA CONFIG_USB_ACM CONFIG_USB_SERIAL \
  CONFIG_XILINX_EMACLITE CONFIG_XILINX_AXI_EMAC CONFIG_MDIO_BITBANG \
  CONFIG_SERIAL_UARTLITE CONFIG_PWM_XILINX CONFIG_XILINX_DMA \
  CONFIG_SND_SOC_XILINX_I2S CONFIG_SND_SOC_XILINX_AUDIO_FORMATTER \
  CONFIG_VIDEO_XILINX CONFIG_VIDEOBUF2_DMA_CONTIG CONFIG_TUN \
  CONFIG_BRIDGE CONFIG_VLAN_8021Q CONFIG_NF_TABLES CONFIG_ZRAM; do
  grep -Eq "^${opt}=(y|m)$" .config || {
    echo "required hardware/profile option missing: $opt" >&2
    exit 3
  }
done
# XADC is not an optional profile endpoint. Keep it resident so the board's
# advertised `sensors` ABI does not silently disappear if the modules payload
# is deliberately minimised in a future image.
grep -qx 'CONFIG_XILINX_XADC=y' .config || {
  echo 'XADC must be built into the AtlANTian kernel' >&2; exit 3;
}

if [[ $TARGET = config ]]; then
  echo "Linux $ATLANTIAN_KERNEL_VERSION configuration contract passed at $ATLANTIAN_KERNEL_COMMIT"
  exit 0
fi
if [[ $TARGET = dtb ]]; then
  make -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" xilinx/zynq-bitmain-antminer-s9.dtb
  mkdir -p "$OUT"
  cp "$DTS_DIR/zynq-bitmain-antminer-s9.dtb" "$OUT/devicetree.dtb"
  echo "Device tree updated in $OUT/devicetree.dtb"
  exit 0
fi

[[ -d "$ROOTFS" ]] || { echo "missing rootfs for full kernel build: $ROOTFS" >&2; exit 2; }
make -j"$JOBS" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" zImage modules xilinx/zynq-bitmain-antminer-s9.dtb
rm -rf "$ROOTFS/lib/modules" "$ROOTFS"/boot/vmlinuz-* "$ROOTFS"/boot/initrd.img-* "$ROOTFS"/boot/System.map-* "$ROOTFS"/boot/config-*
make ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" modules_install INSTALL_MOD_PATH="$ROOTFS"
KVER=$(make -s ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)
depmod -b "$ROOTFS" "$KVER"
mkdir -p "$OUT"
cp arch/arm/boot/zImage "$OUT/zImage"
cp "$DTS_DIR/zynq-bitmain-antminer-s9.dtb" "$OUT/devicetree.dtb"
cp .config "$OUT/kernel.config"
echo "Kernel $KVER created in $OUT"
