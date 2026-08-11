#!/usr/bin/env bash
# Build the complete SD first-stage boot chain from pinned upstream U-Boot.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. config/u-boot.env

SRC=${UBOOT_SRC:-$ROOT/out/u-boot-src}
BUILD=${UBOOT_BUILD:-$ROOT/out/u-boot-build}
OUT=${UBOOT_OUT:-$ROOT/out/bootloader}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}
ATLANTIAN_BOOTCOMMAND='fatload mmc 0:1 0x03000000 boot.scr && source 0x03000000'

fail() { printf 'U-Boot build: %s\n' "$*" >&2; exit 1; }
[[ $ATLANTIAN_UBOOT_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'ATLANTIAN_UBOOT_COMMIT must be a 40-character commit ID'
[[ $ATLANTIAN_UBOOT_DEFCONFIG == bitmain_antminer_s9_defconfig ]] || fail 'unexpected U-Boot board defconfig'
command -v "${CROSS_COMPILE}gcc" >/dev/null || fail "missing ${CROSS_COMPILE}gcc"

mkdir -p "$ROOT/out"
if [[ ! -d $SRC/.git ]]; then
  rm -rf "$SRC"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$ATLANTIAN_UBOOT_REPOSITORY"
else
  git -C "$SRC" remote set-url origin "$ATLANTIAN_UBOOT_REPOSITORY"
fi

# A restored source cache can contain tracked AtlANTian patches from its previous
# build. Reset first; fetch only when the cache does not already contain the pin.
current=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)
if [[ $current == "$ATLANTIAN_UBOOT_COMMIT" ]]; then
  git -C "$SRC" reset --quiet --hard "$ATLANTIAN_UBOOT_COMMIT"
else
  git -C "$SRC" fetch --quiet --depth 1 origin "$ATLANTIAN_UBOOT_COMMIT"
  git -C "$SRC" checkout --quiet --detach --force FETCH_HEAD
fi
git -C "$SRC" clean -ffdqx
test "$(git -C "$SRC" rev-parse HEAD)" = "$ATLANTIAN_UBOOT_COMMIT" || fail 'checked-out U-Boot commit does not match the pin'

# SD recovery/installer U-Boot is allowed to access NAND explicitly, but simply
# probing it must never create a flash BBT. Repository helpers are invoked via
# their interpreter so CI does not depend on Git executable-mode metadata.
bash "$ROOT/scripts/patch-uboot-nand.sh" "$SRC"

rm -rf "$BUILD"
mkdir -p "$BUILD"
make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" "$ATLANTIAN_UBOOT_DEFCONFIG"

# The pinned upstream scripts/config explicitly supports repeated commands in a
# single invocation. Keep this direct upstream interface instead of maintaining
# a local batching shim.
"$SRC/scripts/config" --file "$BUILD/.config" \
  --enable SPL \
  --enable SPL_MMC \
  --enable SPL_FS_FAT \
  --set-str SPL_FS_LOAD_PAYLOAD_NAME 'u-boot.img' \
  --enable CMD_NAND \
  --enable FAT_WRITE \
  --enable CMD_FS_GENERIC \
  --enable CMD_MEMORY \
  --enable USE_BOOTCOMMAND \
  --set-str BOOTCOMMAND "$ATLANTIAN_BOOTCOMMAND" \
  --enable ENV_IS_NOWHERE \
  --disable ENV_IS_IN_FAT \
  --disable ENV_IS_IN_NAND \
  --disable WATCHDOG_AUTOSTART \
  --disable TOOLS_MKEFICAPSULE
make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

for contract in \
  'CONFIG_ARCH_ZYNQ=y' \
  'CONFIG_SPL=y' \
  'CONFIG_SPL_MMC=y' \
  'CONFIG_SPL_FS_FAT=y' \
  'CONFIG_SPL_FS_LOAD_PAYLOAD_NAME="u-boot.img"' \
  'CONFIG_CMD_NAND=y' \
  'CONFIG_FAT_WRITE=y' \
  'CONFIG_USE_BOOTCOMMAND=y' \
  "CONFIG_BOOTCOMMAND=\"$ATLANTIAN_BOOTCOMMAND\"" \
  'CONFIG_ENV_IS_NOWHERE=y' \
  '# CONFIG_ENV_IS_IN_FAT is not set' \
  '# CONFIG_ENV_IS_IN_NAND is not set' \
  'CONFIG_WDT=y' \
  'CONFIG_WDT_CDNS=y' \
  '# CONFIG_WATCHDOG_AUTOSTART is not set' \
  '# CONFIG_TOOLS_MKEFICAPSULE is not set' \
  'CONFIG_DEFAULT_DEVICE_TREE="bitmain-antminer-s9"'; do
  grep -Fqx "$contract" "$BUILD/.config" || fail "missing generated config contract: $contract"
done

make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"

test -s "$BUILD/spl/boot.bin" || fail 'SPL Zynq boot.bin was not produced'
test -s "$BUILD/u-boot.img" || fail 'u-boot.img was not produced'

# Verify the generated binary really contains the default autoboot command.
strings -a "$BUILD/u-boot.img" > "$BUILD/u-boot.strings"
grep -Fqx "bootcmd=$ATLANTIAN_BOOTCOMMAND" "$BUILD/u-boot.strings" || \
  fail 'u-boot.img does not contain the AtlANTian SD autoboot command'

rm -rf "$OUT"
mkdir -p "$OUT"
install -m 0644 "$BUILD/spl/boot.bin" "$OUT/BOOT.bin"
install -m 0644 "$BUILD/u-boot.img" "$OUT/u-boot.img"
printf '%s\n' "$ATLANTIAN_UBOOT_COMMIT" > "$OUT/u-boot.commit"
printf '%s\n' "$ATLANTIAN_UBOOT_VERSION" > "$OUT/u-boot.version"

printf 'Built U-Boot %s (%s) for Antminer S9 SD/recovery: %s + %s\n' \
  "$ATLANTIAN_UBOOT_VERSION" "$ATLANTIAN_UBOOT_COMMIT" "$OUT/BOOT.bin" "$OUT/u-boot.img"
