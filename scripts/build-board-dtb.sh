#!/usr/bin/env bash
# Build the Antminer S9 DTB against a current Linux 6.12 source tree.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$PROJECT/out/linux-src}
OUT=${OUT:-$PROJECT/out/boot/zynq-bitmain-antminer-s9.dtb}
BOARD_DTS=${BOARD_DTS:-$PROJECT/board/zynq-bitmain-antminer-s9.dts}
KERNEL_TAG=${KERNEL_TAG:-v6.12}

[[ -f "$BOARD_DTS" ]] || { echo "missing board DTS: $BOARD_DTS" >&2; exit 2; }
if [[ ! -d "$WORK/.git" ]]; then
  git clone --depth 1 --branch "$KERNEL_TAG" https://github.com/torvalds/linux.git "$WORK"
fi

DTS_DIR="$WORK/arch/arm/boot/dts"
mkdir -p "$(dirname "$OUT")"
# A board DTB is independent of Kconfig. Compile it directly: this avoids
# mutating the configured kernel tree or accidentally replacing the AtlANTian
# kernel configuration with multi_v7_defconfig.
cpp -nostdinc -undef -x assembler-with-cpp \
  -I"$DTS_DIR" -I"$DTS_DIR/xilinx" -I"$WORK/include" \
  "$BOARD_DTS" >"$PROJECT/out/zynq-bitmain-antminer-s9.pre.dts"
dtc -@ -I dts -O dtb -o "$OUT" "$PROJECT/out/zynq-bitmain-antminer-s9.pre.dts"
fdtdump "$OUT" | head -n 20
echo "Board DTB created: $OUT"
