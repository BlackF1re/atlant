#!/usr/bin/env bash
# Build the NAND first-stage/main U-Boot flavor from the same pinned upstream
# source as the production SD bootloader.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. config/u-boot.env
. config/nand-layout.env

SRC=${UBOOT_SRC:-$ROOT/out/u-boot-src}
BUILD=${UBOOT_NAND_BUILD:-$ROOT/out/u-boot-nand-build}
OUT=${UBOOT_NAND_OUT:-$ROOT/out/bootloader/nand}
INITRAMFS=${INITRAMFS:-$ROOT/out/nand/initramfs.cpio.gz}
ZIMAGE=${ZIMAGE:-$ROOT/out/boot/zImage}
DTB=${DTB:-$ROOT/out/boot/devicetree.dtb}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}

fail() { printf 'NAND U-Boot build: %s\n' "$*" >&2; exit 1; }
command -v "${CROSS_COMPILE}gcc" >/dev/null || fail "missing ${CROSS_COMPILE}gcc"
for f in "$ZIMAGE" "$DTB" "$INITRAMFS"; do [[ -s $f ]] || fail "missing NAND boot-size input: $f"; done

# uImage/uInitrd each add one 64-byte image header. NAND reads are logical and
# skip bad eraseblocks, so reading an entire reserved slot could continue into
# the next physical slot. Compile the exact payload lengths into this release's
# immutable bootcmd; slot sizes remain only physical/bad-block headroom.
kernel_size=$(($(stat -c %s "$ZIMAGE") + 64))
initrd_size=$(($(stat -c %s "$INITRAMFS") + 64))
dtb_size=$(stat -c %s "$DTB")
((kernel_size <= ATLANTIAN_NAND_KERNEL_SLOT_BYTES)) || fail "uImage size $kernel_size exceeds NAND kernel slot"
((initrd_size <= ATLANTIAN_NAND_INITRD_SLOT_BYTES)) || fail "uInitrd size $initrd_size exceeds NAND initrd slot"
((dtb_size <= ATLANTIAN_NAND_DTB_SLOT_BYTES)) || fail "DTB size $dtb_size exceeds NAND DTB slot"
printf -v kernel_hex '0x%X' "$kernel_size"
printf -v initrd_hex '0x%X' "$initrd_size"
printf -v dtb_hex '0x%X' "$dtb_size"
printf -v nand_block_hex '0x%X' "$ATLANTIAN_NAND_ERASE_BYTES"
NAND_BOOTCOMMAND="nand info; setenv bootargs console=ttyPS0,115200n8 mtdparts=pl35x-nand-controller:16m(atlantian-boot),-(atlantian-ubi); if nand read 0x02000000 0x00300000 $kernel_hex && nand read 0x08000000 0x00C00000 $initrd_hex && nand read 0x01F00000 0x00F00000 $dtb_hex; then bootm 0x02000000 0x08000000 0x01F00000; fi; echo AtlANTian NAND boot failed"

mkdir -p "$ROOT/out"
if [[ ! -d $SRC/.git ]]; then
  rm -rf "$SRC"; git init -q "$SRC"; git -C "$SRC" remote add origin "$ATLANTIAN_UBOOT_REPOSITORY"
else
  git -C "$SRC" remote set-url origin "$ATLANTIAN_UBOOT_REPOSITORY"
fi
current=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)
if [[ $current == "$ATLANTIAN_UBOOT_COMMIT" ]]; then
  git -C "$SRC" reset --quiet --hard "$ATLANTIAN_UBOOT_COMMIT"
else
  git -C "$SRC" fetch --quiet --depth 1 origin "$ATLANTIAN_UBOOT_COMMIT"
  git -C "$SRC" checkout --quiet --detach --force FETCH_HEAD
fi
git -C "$SRC" clean -ffdqx
test "$(git -C "$SRC" rev-parse HEAD)" = "$ATLANTIAN_UBOOT_COMMIT"

# Runtime U-Boot keeps the normal DM NAND driver. xPL receives a dedicated,
# fixed-geometry Zynq reader which does no nand_scan_ident/BBT writes and uses
# bounded R/B polling instead of the timer-dependent generic wait helper.
bash "$ROOT/scripts/patch-uboot-nand.sh" "$SRC" --spl-loader

# Fixed raw offsets and the stock NAND geometry are compile-time SPL contracts.
# Derive them from the same repository policy used by the installer rather than
# duplicating page/block/slot sizes inside the C reader.
total_bytes=$((ATLANTIAN_NAND_TOTAL_MIB * 1024 * 1024))
python3 - "$SRC/include/configs/bitmain_antminer_s9.h" \
  "$ATLANTIAN_NAND_PAGE_BYTES" "$ATLANTIAN_NAND_OOB_BYTES" \
  "$ATLANTIAN_NAND_ERASE_BYTES" "$total_bytes" \
  "$ATLANTIAN_NAND_UBOOT_PRIMARY_OFFSET" "$ATLANTIAN_NAND_UBOOT_REDUND_OFFSET" \
  "$ATLANTIAN_NAND_UBOOT_SLOT_BYTES" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); t = p.read_text()
page, oob, erase, total, primary, redund, slot = map(int, sys.argv[2:])
if erase % page:
    raise SystemExit('NAND erase geometry is not page aligned')
needle = '#define CFG_SYS_SDRAM_SIZE\t0x40000000\n'
block = f'''#define CFG_SYS_SDRAM_SIZE\t0x40000000

/* AtlANTian NAND SPL contract; physical SD/NAND selection remains BootROM policy. */
#define CONFIG_SYS_NAND_U_BOOT_OFFS\t0x{primary:08X}
#define CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND\t0x{redund:08X}
#define CFG_SYS_NAND_U_BOOT_SIZE\t0x{slot:08X}
#define CFG_SYS_NAND_U_BOOT_DST\t0x04000000
#define CFG_SYS_NAND_U_BOOT_START\tCFG_SYS_NAND_U_BOOT_DST
#define ATLANTIAN_SPL_NAND_SMC_BASE\t0xE000E000UL
#define ATLANTIAN_SPL_NAND_DATA_BASE\t0xE1000000UL
#define ATLANTIAN_SPL_NAND_TOTAL_BYTES\t0x{total:08X}UL
#define ATLANTIAN_SPL_NAND_PAGE_BYTES\t{page}U
#define ATLANTIAN_SPL_NAND_OOB_BYTES\t{oob}U
#define ATLANTIAN_SPL_NAND_BLOCK_BYTES\t{erase}U
#define ATLANTIAN_SPL_NAND_ADDR_CYCLES\t0x23U
#define ATLANTIAN_SPL_NAND_BAD_BLOCK_POS\t0U
'''
if 'AtlANTian NAND SPL contract' not in t:
    if needle not in t:
        raise SystemExit('cannot locate S9 SDRAM header anchor')
    t = t.replace(needle, block, 1)
p.write_text(t)
PY

rm -rf "$BUILD"; mkdir -p "$BUILD"
make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" "$ATLANTIAN_UBOOT_DEFCONFIG"

# SPL_NAND_SUPPORT exposes SYS_NAND_BLOCK_SIZE as a mandatory hex Kconfig value.
"$SRC/scripts/config" --file "$BUILD/.config" \
  --enable SPL \
  --enable SPL_NAND_SUPPORT \
  --enable SPL_NAND_DRIVERS \
  --enable SPL_NAND_BASE \
  --enable SPL_NAND_IDENT \
  --enable SPL_NAND_INIT \
  --enable SPL_NAND_ECC \
  --enable MTD_RAW_NAND \
  --enable NAND_ZYNQ \
  --set-val SYS_NAND_BLOCK_SIZE "$nand_block_hex" \
  --enable CMD_NAND \
  --enable CMD_MEMORY \
  --enable USE_BOOTCOMMAND \
  --set-str BOOTCOMMAND "$NAND_BOOTCOMMAND" \
  --enable ENV_IS_NOWHERE \
  --disable ENV_IS_IN_FAT \
  --disable ENV_IS_IN_NAND \
  --disable WATCHDOG_AUTOSTART \
  --disable TOOLS_MKEFICAPSULE

kconfig_log="$BUILD/kconfig-olddefconfig.log"
if ! timeout 60s make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig </dev/null >"$kconfig_log" 2>&1; then
  tail -n 120 "$kconfig_log" >&2 || true
  fail 'olddefconfig did not complete non-interactively within 60 seconds'
fi

grep -Fqx "CONFIG_SYS_NAND_BLOCK_SIZE=$nand_block_hex" "$BUILD/.config" || \
  fail "generated SYS_NAND_BLOCK_SIZE does not match NAND erase geometry ($nand_block_hex)"
if grep -Eq '^CONFIG_[A-Z0-9_]+=$' "$BUILD/.config"; then
  grep -E '^CONFIG_[A-Z0-9_]+=$' "$BUILD/.config" >&2 || true
  fail 'generated U-Boot .config contains an empty Kconfig value'
fi

prepare_log="$BUILD/kconfig-prepare.log"
if ! timeout 60s make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" prepare </dev/null >"$prepare_log" 2>&1; then
  tail -n 120 "$prepare_log" >&2 || true
  fail 'prepare did not complete non-interactively within 60 seconds'
fi
for xpl_contract in 'CONFIG_XPL_BUILD=y' 'CONFIG_SPL_BUILD=y'; do
  grep -Fqx "$xpl_contract" "$BUILD/spl/include/autoconf.mk" || \
    fail "missing generated SPL configuration contract: $xpl_contract"
done

for contract in \
  'CONFIG_ARCH_ZYNQ=y' 'CONFIG_SPL=y' 'CONFIG_SPL_NAND_SUPPORT=y' \
  'CONFIG_SPL_MTD=y' 'CONFIG_SPL_NAND_DRIVERS=y' 'CONFIG_SPL_NAND_BASE=y' \
  'CONFIG_SPL_NAND_IDENT=y' 'CONFIG_SPL_NAND_INIT=y' 'CONFIG_SPL_NAND_ECC=y' \
  'CONFIG_NAND_ZYNQ=y' 'CONFIG_CMD_NAND=y' \
  "CONFIG_SYS_NAND_BLOCK_SIZE=$nand_block_hex" \
  'CONFIG_ENV_IS_NOWHERE=y' '# CONFIG_ENV_IS_IN_NAND is not set' \
  '# CONFIG_WATCHDOG_AUTOSTART is not set'; do
  grep -Fqx "$contract" "$BUILD/.config" || fail "missing generated config contract: $contract"
done

make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"
test -s "$BUILD/spl/boot.bin" || fail 'NAND-capable SPL boot.bin was not produced'
test -s "$BUILD/u-boot.img" || fail 'NAND u-boot.img was not produced'

# Prove the generated SPL contains the dedicated reader and that the runtime
# DM-probe diagnostic is not linked into xPL.
spl_strings="$BUILD/spl/boot.bin.strings"
strings -a "$BUILD/spl/boot.bin" >"$spl_strings"
for spl_diag in \
  'AtlANTian SPL NAND: fixed-geometry init' \
  'AtlANTian SPL NAND: Micron 2c:da on-die ECC ready' \
  'AtlANTian SPL NAND: ready timeout' \
  'AtlANTian SPL NAND: factory-bad block' \
  'AtlANTian SPL NAND: U-Boot slot exhausted by bad blocks'; do
  grep -Fq "$spl_diag" "$spl_strings" || \
    fail "generated SPL is missing dedicated NAND reader contract: $spl_diag"
done
if grep -Fq 'AtlANTian SPL NAND: Zynq NAND probe failed' "$spl_strings"; then
  fail 'generated SPL unexpectedly contains the DM NAND probe path'
fi

spl_size=$(stat -c %s "$BUILD/spl/boot.bin")
((spl_size <= ATLANTIAN_NAND_ERASE_BYTES)) || fail "BOOT.bin is $spl_size bytes and no longer fits one NAND eraseblock"
strings -a "$BUILD/u-boot.img" >"$BUILD/u-boot.strings"
grep -Fqx "bootcmd=$NAND_BOOTCOMMAND" "$BUILD/u-boot.strings" || fail 'NAND bootcmd is absent from u-boot.img'

rm -rf "$OUT"; mkdir -p "$OUT"
install -m 0644 "$BUILD/spl/boot.bin" "$OUT/BOOT.bin"
install -m 0644 "$BUILD/u-boot.img" "$OUT/u-boot.img"
printf '%s\n' "$ATLANTIAN_UBOOT_COMMIT" >"$OUT/u-boot.commit"
printf '%s\n' "$ATLANTIAN_UBOOT_VERSION" >"$OUT/u-boot.version"
printf 'kernel=%s\ninitrd=%s\ndtb=%s\n' "$kernel_size" "$initrd_size" "$dtb_size" >"$OUT/raw-boot-sizes.env"
echo "Built NAND U-Boot $ATLANTIAN_UBOOT_VERSION: eraseblock=$nand_block_hex exact raw reads kernel=$kernel_size initrd=$initrd_size dtb=$dtb_size"
