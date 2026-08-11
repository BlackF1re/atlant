#!/usr/bin/env bash
# Build the tiny early userspace that attaches UBI, exposes the immutable static
# volume through ubiblock and assembles SquashFS + OverlayFS.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS=${ROOTFS:-$PROJECT/out/rootfs-nand}
OUT=${OUT:-$PROJECT/out/nand/initramfs.cpio.gz}
INIT_SOURCE=$PROJECT/scripts/atlantian-nand-init.sh
BUSYBOX=${BUSYBOX:-$ROOTFS/usr/bin/busybox}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

for cmd in readelf cpio gzip touch; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 69; }; done
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || { echo 'SOURCE_DATE_EPOCH must be numeric' >&2; exit 64; }
[[ -x $BUSYBOX ]] || { echo "NAND rootfs must contain busybox-static at $BUSYBOX" >&2; exit 2; }
[[ -x $ROOTFS/usr/sbin/ubiattach ]] || { echo 'NAND rootfs must contain mtd-utils ubiattach' >&2; exit 2; }
[[ -x $ROOTFS/usr/sbin/ubiblock ]] || { echo 'NAND rootfs must contain mtd-utils ubiblock' >&2; exit 2; }
[[ -s $INIT_SOURCE ]] || { echo "missing $INIT_SOURCE" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
init=$work/initramfs
mkdir -p "$init"/{bin,sbin,usr/bin,usr/sbin,lib,proc,sys,dev,run,newroot}
install -m 0755 "$INIT_SOURCE" "$init/init"
cp -L "$BUSYBOX" "$init/bin/busybox"
chmod 0755 "$init/bin/busybox"
for applet in sh mount umount mkdir cat sleep awk; do ln -s busybox "$init/bin/$applet"; done

# Copy ARM mtd-utils plus all ELF dependencies without executing target binaries
# on the x86 build host.
declare -A copied=()
copy_elf() {
  local src=$1 rel=${2:-${src#"$ROOTFS"}}
  [[ $src == "$ROOTFS"/* ]] || { echo "refusing non-rootfs ELF: $src" >&2; exit 2; }
  [[ -f $src ]] || { echo "missing ELF dependency: $src" >&2; exit 2; }
  [[ ${copied[$rel]+x} ]] && return 0
  copied[$rel]=1
  mkdir -p "$init/$(dirname "$rel")"
  cp -L "$src" "$init/$rel"

  local interp lib found
  interp=$(readelf -l "$src" 2>/dev/null | sed -n 's@.*Requesting program interpreter: \([^]]*\).*@\1@p' | head -n1 || true)
  if [[ -n $interp && -e $ROOTFS$interp ]]; then copy_elf "$ROOTFS$interp" "$interp"; fi
  while IFS= read -r lib; do
    [[ -n $lib ]] || continue
    found=$(find "$ROOTFS/lib" "$ROOTFS/usr/lib" \( -type f -o -type l \) -name "$lib" -print -quit 2>/dev/null || true)
    [[ -n $found ]] || { echo "cannot resolve $lib required by $src" >&2; exit 2; }
    copy_elf "$found" "${found#"$ROOTFS"}"
  done < <(readelf -d "$src" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
}

copy_elf "$ROOTFS/usr/sbin/ubiattach" /sbin/ubiattach
copy_elf "$ROOTFS/usr/sbin/ubiblock" /sbin/ubiblock

# NAND U-Boot embeds the exact uInitrd byte length in its bootcmd. Make the
# cpio payload byte-reproducible as well as gzip-timestamp-free: normalize
# mtimes and ask GNU cpio to renumber inodes/ignore device-number variance.
find "$init" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
mkdir -p "$(dirname "$OUT")"
(
  cd "$init"
  find . -print0 | LC_ALL=C sort -z | cpio --null --quiet --reproducible -o -H newc --owner=0:0
) | gzip -9n >"$OUT"

test -s "$OUT"
echo "Created deterministic NAND initramfs: $OUT ($(stat -c %s "$OUT") bytes; decompressed once at boot)"
