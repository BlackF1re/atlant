#!/usr/bin/env bash
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=${1:-$PROJECT/out/nand/bundle}
IMAGE=${2:-}
SIZES=${RAW_BOOT_SIZES:-$PROJECT/out/bootloader/nand/raw-boot-sizes.env}
[[ -s $BUNDLE/NAND-MANIFEST.json && -s $BUNDLE/SHA256SUMS ]] || { echo 'NAND bundle metadata missing' >&2; exit 2; }
[[ -s $SIZES ]] || { echo "NAND U-Boot raw-boot-sizes.env missing: $SIZES" >&2; exit 2; }
(cd "$BUNDLE" && sha256sum -c SHA256SUMS)

. "$SIZES"
actual_kernel=$(stat -c %s "$BUNDLE/uImage")
actual_initrd=$(stat -c %s "$BUNDLE/uInitrd")
actual_dtb=$(stat -c %s "$BUNDLE/devicetree.dtb")
[[ $actual_kernel -eq ${kernel:?} ]] || { echo "NAND U-Boot kernel read length mismatch: compiled=$kernel bundle=$actual_kernel" >&2; exit 1; }
[[ $actual_initrd -eq ${initrd:?} ]] || { echo "NAND U-Boot initrd read length mismatch: compiled=$initrd bundle=$actual_initrd" >&2; exit 1; }
[[ $actual_dtb -eq ${dtb:?} ]] || { echo "NAND U-Boot DTB read length mismatch: compiled=$dtb bundle=$actual_dtb" >&2; exit 1; }

python3 - "$BUNDLE/NAND-MANIFEST.json" <<'PY'
import json, sys
with open(sys.argv[1],encoding='utf-8') as f: m=json.load(f)
assert m['schema_version'] == 1
assert m['product'] == 'atlantian-nand'
assert m['compression']['rootfs_squashfs'] == 'zstd'
assert 1 <= m['compression']['rootfs_zstd_level'] <= 22
assert m['compression']['overlay_ubifs'] == 'lzo'
assert m['compression']['initramfs'] == 'gzip-one-shot'
n=m['nand']; v=m['volumes']; b=m['boot']; files=m['files']
assert n['total_bytes'] == 256*1024*1024
assert n['boot_bytes'] == n['ubi_offset_bytes'] == 16*1024*1024
assert n['erase_bytes'] == 128*1024 and n['page_bytes'] == 2048 and n['oob_bytes'] == 64
assert v['rootfs']['type'] == 'static'
assert v['rootfs']['filesystem'] == 'squashfs'
assert v['rootfs']['mount'] == 'ro,ubiblock'
assert v['rootfs']['image_bytes'] == files['rootfs.squashfs']['bytes']
assert v['rootfs']['image_bytes'] <= v['rootfs']['bytes']
assert v['rootfs']['bytes'] == v['rootfs']['lebs'] * n['leb_bytes']
assert v['overlay']['type'] == 'dynamic'
assert v['overlay']['filesystem'] == 'ubifs'
assert v['overlay']['mount'] == 'rw,noatime,compr=lzo'
assert v['overlay']['autoresize'] is False
assert v['overlay']['allocation'] == 'maximum-available-at-install'
assert v['overlay']['minimum_lebs'] * n['leb_bytes'] >= 32*1024*1024
assert b['kernel_offset'] + b['kernel_slot_bytes'] == b['initrd_offset']
assert b['initrd_offset'] + b['initrd_slot_bytes'] == b['dtb_offset']
assert b['dtb_offset'] + b['dtb_slot_bytes'] == n['ubi_offset_bytes']
assert files['uImage']['bytes'] <= b['kernel_slot_bytes']
assert files['uInitrd']['bytes'] <= b['initrd_slot_bytes']
assert files['devicetree.dtb']['bytes'] <= b['dtb_slot_bytes']
assert files['u-boot.img']['bytes'] <= 1024*1024
root_lebs=v['rootfs']['lebs']; overlay=v['overlay']['minimum_lebs']; reserve=n['ci_bad_peb_reserve']
assert root_lebs + overlay + reserve + 8 <= n['ubi_pebs']
print(
    f"NAND footprint: raw boot {n['boot_bytes']/1048576:.0f} MiB + "
    f"SquashFS {v['rootfs']['image_bytes']/1048576:.2f} MiB "
    f"({v['rootfs']['bytes']/1048576:.2f} MiB static UBI); "
    "writable UBIFS compressor: lzo; allocation: maximum available at install"
)
PY

python3 - "$BUNDLE/rootfs.squashfs" <<'PY'
import struct,sys
with open(sys.argv[1],'rb') as f: magic=struct.unpack('<I',f.read(4))[0]
if magic != 0x73717368: raise SystemExit(f'rootfs.squashfs has unexpected magic 0x{magic:08x}')
PY

if [[ -n $IMAGE ]]; then
  [[ -s $IMAGE ]] || { echo "unified release image missing: $IMAGE" >&2; exit 2; }
  sudo -E bash "$PROJECT/scripts/test-image-layout.sh" "$IMAGE"

  loop=$(sudo losetup --find --show --partscan "$IMAGE")
  mnt=$(mktemp -d)
  cleanup() {
    sudo umount "$mnt" >/dev/null 2>&1 || true
    sudo losetup -d "$loop" >/dev/null 2>&1 || true
    rmdir "$mnt" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM HUP
  sudo mount -o ro "${loop}p2" "$mnt"
  embedded="$mnt/usr/lib/atlantian/nand"
  [[ -s $embedded/NAND-MANIFEST.json && -s $embedded/SHA256SUMS ]] || { echo 'unified image does not contain the NAND payload' >&2; exit 1; }
  (cd "$embedded" && sha256sum -c SHA256SUMS >/dev/null)
  cmp "$BUNDLE/NAND-MANIFEST.json" "$embedded/NAND-MANIFEST.json"
  cmp "$BUNDLE/SHA256SUMS" "$embedded/SHA256SUMS"
  cleanup
  trap - EXIT INT TERM HUP
fi
