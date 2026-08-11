#!/usr/bin/env bash
# Build the NAND payload. Immutable userspace is a dense Zstd SquashFS in a
# static UBI volume; only the writable OverlayFS upper uses UBIFS (LZO).
# BootROM, SPL, U-Boot, kernel, DTB and initramfs stay in the raw boot region;
# the observed Micron NAND's on-die BCH 4/512 protects both boot and UBI data.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT"
. config/release.env
. config/nand-layout.env
export ATLANTIAN_VERSION ATLANTIAN_RELEASE_ID

ROOTFS=${ROOTFS:-$PROJECT/out/rootfs-nand}
NAND_BOOT=${NAND_BOOT:-$PROJECT/out/bootloader/nand}
DTB=${DTB:-$PROJECT/out/boot/devicetree.dtb}
ZIMAGE=${ZIMAGE:-$PROJECT/out/boot/zImage}
INITRAMFS=${INITRAMFS:-$PROJECT/out/nand/initramfs.cpio.gz}
OUTDIR=${OUTDIR:-$PROJECT/out/nand/bundle}
PUBLIC=${PUBLIC:-$PROJECT/artifacts/current/atlantian-nand-${ATLANTIAN_VERSION}.tar.zst}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

for cmd in mksquashfs mkimage sha256sum python3 zstd; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 69; }; done
for f in "$NAND_BOOT/BOOT.bin" "$NAND_BOOT/u-boot.img" "$DTB" "$ZIMAGE" "$INITRAMFS"; do
  [[ -s $f ]] || { echo "missing NAND bundle input: $f" >&2; exit 2; }
done
[[ -d $ROOTFS ]] || { echo "missing NAND rootfs: $ROOTFS" >&2; exit 2; }
[[ $ATLANTIAN_NAND_ROOTFS_FORMAT == squashfs ]] || { echo 'NAND immutable rootfs must be SquashFS' >&2; exit 2; }
[[ $ATLANTIAN_NAND_ROOTFS_COMPRESSOR == zstd ]] || { echo 'NAND SquashFS compressor must be zstd' >&2; exit 2; }
[[ $ATLANTIAN_NAND_OVERLAY_COMPRESSOR == lzo ]] || { echo 'NAND UBIFS overlay compressor must be lzo' >&2; exit 2; }
[[ $ATLANTIAN_NAND_ROOTFS_BLOCK_BYTES =~ ^[0-9]+$ && $ATLANTIAN_NAND_ROOTFS_ZSTD_LEVEL =~ ^[0-9]+$ ]] || { echo 'invalid SquashFS policy' >&2; exit 2; }

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR" "$(dirname "$PUBLIC")"
# Kernel/initramfs are raw-boot assets, not duplicated inside the immutable root.
rm -rf "$ROOTFS/boot"/* 2>/dev/null || true

mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 \
  -n "AtlANTian NAND ${ATLANTIAN_RELEASE_ID}" -d "$ZIMAGE" "$OUTDIR/uImage"
mkimage -A arm -O linux -T ramdisk -C gzip -a 0 -e 0 \
  -n "AtlANTian NAND initramfs ${ATLANTIAN_RELEASE_ID}" -d "$INITRAMFS" "$OUTDIR/uInitrd"
install -m 0644 "$DTB" "$OUTDIR/devicetree.dtb"

# Fail closed if a boot asset can consume its following raw slot even before
# factory-bad blocks are taken into account. The U-Boot stage also performs a
# complete second read-back after all writes to catch bad-block spillover.
(( $(stat -c %s "$OUTDIR/uImage") <= ATLANTIAN_NAND_KERNEL_SLOT_BYTES )) || { echo 'NAND kernel exceeds raw slot' >&2; exit 75; }
(( $(stat -c %s "$OUTDIR/uInitrd") <= ATLANTIAN_NAND_INITRD_SLOT_BYTES )) || { echo 'NAND initramfs exceeds raw slot' >&2; exit 75; }
(( $(stat -c %s "$OUTDIR/devicetree.dtb") <= ATLANTIAN_NAND_DTB_SLOT_BYTES )) || { echo 'NAND DTB exceeds raw slot' >&2; exit 75; }

# SquashFS is substantially denser than a read-only UBIFS volume because the
# immutable base needs neither UBIFS journal/index headroom nor writable-space
# accounting. Keep xattrs/capabilities, duplicate detection and fragment packing;
# omit only NFS export metadata, which this appliance root never uses.
export SOURCE_DATE_EPOCH
mksquashfs "$ROOTFS" "$OUTDIR/rootfs.squashfs" \
  -noappend -comp zstd -Xcompression-level "$ATLANTIAN_NAND_ROOTFS_ZSTD_LEVEL" \
  -b "$ATLANTIAN_NAND_ROOTFS_BLOCK_BYTES" -no-progress -no-recovery -no-exports
root_image_bytes=$(stat -c %s "$OUTDIR/rootfs.squashfs")
root_lebs=$(((root_image_bytes + ATLANTIAN_NAND_LEB_BYTES - 1) / ATLANTIAN_NAND_LEB_BYTES))
root_volume_bytes=$((root_lebs * ATLANTIAN_NAND_LEB_BYTES))

total_pebs=$((ATLANTIAN_NAND_UBI_MIB * 1024 * 1024 / ATLANTIAN_NAND_ERASE_BYTES))
min_overlay_lebs=$(((ATLANTIAN_NAND_MIN_OVERLAY_MIB * 1024 * 1024 + ATLANTIAN_NAND_LEB_BYTES - 1) / ATLANTIAN_NAND_LEB_BYTES))
# Eight additional PEBs cover UBI internal/service overhead on top of the
# explicit bad-PEB reserve. The physical board remains the final authority.
max_root_lebs=$((total_pebs - ATLANTIAN_NAND_CI_BAD_PEB_RESERVE - min_overlay_lebs - 8))
(( root_lebs <= max_root_lebs )) || {
  echo "Compressed NAND rootfs still cannot fit while preserving ${ATLANTIAN_NAND_MIN_OVERLAY_MIB} MiB overlay and bad-PEB reserve" >&2
  echo "rootfs.squashfs=$root_image_bytes bytes, needs $root_lebs LEBs; maximum is $max_root_lebs" >&2
  exit 75
}

install -m 0644 "$NAND_BOOT/BOOT.bin" "$OUTDIR/BOOT.bin"
install -m 0644 "$NAND_BOOT/u-boot.img" "$OUTDIR/u-boot.img"
(( $(stat -c %s "$OUTDIR/u-boot.img") <= ATLANTIAN_NAND_UBOOT_SLOT_BYTES )) || { echo 'NAND U-Boot exceeds raw slot' >&2; exit 75; }
python3 - "$OUTDIR/BOOT.bin" "$OUTDIR/spl-redundant.bin" "$ATLANTIAN_NAND_ERASE_BYTES" "$ATLANTIAN_NAND_SPL_COPIES" <<'PY'
from pathlib import Path
import sys
src, dst, erase, copies = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = Path(src).read_bytes()
if len(data) > erase: raise SystemExit(f"BOOT.bin ({len(data)}) exceeds eraseblock ({erase})")
Path(dst).write_bytes((data + b"\xff" * (erase-len(data))) * copies)
PY

# SD U-Boot writes every raw boot asset through the same Micron on-die ECC path
# later used by BootROM and NAND U-Boot. Keep the generated hush script simple:
# each operation has its own short conditional and flips a fail-closed flag before
# any later write.
stage_txt=$(mktemp)
trap 'rm -f "$stage_txt"' EXIT
cat >"$stage_txt" <<'EOF_STAGE'
echo AtlANTian NAND boot-stage check...
if fatload mmc 0:1 0x0A000000 atln-stage.done; then
    echo NAND raw boot stage already verified.
else
    echo Programming and verifying AtlANTian raw NAND boot area...
    setenv atln_stage_ok 1

    if nand info; then
        echo NAND probe passed.
    else
        echo ERROR: NAND probe failed.
        setenv atln_stage_ok 0
    fi

    if test "${atln_stage_ok}" = "1"; then
        if nand erase 0x00000000 0x01000000; then
            echo NAND raw boot erase passed.
        else
            echo ERROR: NAND raw boot erase failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-spl.bin; then
            setenv atln_spl_size ${filesize}
        else
            echo ERROR: could not load staged SPL.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand write 0x08000000 0x00000000 ${atln_spl_size}; then
            echo SPL write passed.
        else
            echo ERROR: SPL write failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00000000 ${atln_spl_size}; then
            echo SPL immediate read-back passed.
        else
            echo ERROR: SPL immediate read-back failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_spl_size}; then
            echo SPL immediate compare passed.
        else
            echo ERROR: SPL immediate compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-uboot.img; then
            setenv atln_uboot_size ${filesize}
        else
            echo ERROR: could not load staged U-Boot.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand write 0x08000000 0x00100000 ${atln_uboot_size}; then
            echo Primary U-Boot write passed.
        else
            echo ERROR: primary U-Boot write failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00100000 ${atln_uboot_size}; then
            echo Primary U-Boot immediate read-back passed.
        else
            echo ERROR: primary U-Boot immediate read-back failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_uboot_size}; then
            echo Primary U-Boot immediate compare passed.
        else
            echo ERROR: primary U-Boot immediate compare failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand write 0x08000000 0x00200000 ${atln_uboot_size}; then
            echo Redundant U-Boot write passed.
        else
            echo ERROR: redundant U-Boot write failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00200000 ${atln_uboot_size}; then
            echo Redundant U-Boot immediate read-back passed.
        else
            echo ERROR: redundant U-Boot immediate read-back failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_uboot_size}; then
            echo Redundant U-Boot immediate compare passed.
        else
            echo ERROR: redundant U-Boot immediate compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-kernel.img; then
            setenv atln_kernel_size ${filesize}
        else
            echo ERROR: could not load staged kernel.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand write 0x08000000 0x00300000 ${atln_kernel_size}; then
            echo Kernel write passed.
        else
            echo ERROR: kernel write failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00300000 ${atln_kernel_size}; then
            echo Kernel immediate read-back passed.
        else
            echo ERROR: kernel immediate read-back failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_kernel_size}; then
            echo Kernel immediate compare passed.
        else
            echo ERROR: kernel immediate compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-initrd.img; then
            setenv atln_initrd_size ${filesize}
        else
            echo ERROR: could not load staged initramfs.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand write 0x08000000 0x00C00000 ${atln_initrd_size}; then
            echo Initramfs write passed.
        else
            echo ERROR: initramfs write failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00C00000 ${atln_initrd_size}; then
            echo Initramfs immediate read-back passed.
        else
            echo ERROR: initramfs immediate read-back failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_initrd_size}; then
            echo Initramfs immediate compare passed.
        else
            echo ERROR: initramfs immediate compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-dtb.bin; then
            setenv atln_dtb_size ${filesize}
        else
            echo ERROR: could not load staged DTB.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand write 0x08000000 0x00F00000 ${atln_dtb_size}; then
            echo DTB write passed.
        else
            echo ERROR: DTB write failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00F00000 ${atln_dtb_size}; then
            echo DTB immediate read-back passed.
        else
            echo ERROR: DTB immediate read-back failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_dtb_size}; then
            echo DTB immediate compare passed.
        else
            echo ERROR: DTB immediate compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        echo Final full-layout read-back verification...
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-spl.bin; then
            echo Reloaded SPL for final verification.
        else
            echo ERROR: could not reload SPL for final verification.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00000000 ${atln_spl_size}; then
            echo Final SPL read passed.
        else
            echo ERROR: final SPL read failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_spl_size}; then
            echo Final SPL compare passed.
        else
            echo ERROR: final SPL compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-uboot.img; then
            echo Reloaded U-Boot for final verification.
        else
            echo ERROR: could not reload U-Boot for final verification.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00100000 ${atln_uboot_size}; then
            echo Final primary U-Boot read passed.
        else
            echo ERROR: final primary U-Boot read failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_uboot_size}; then
            echo Final primary U-Boot compare passed.
        else
            echo ERROR: final primary U-Boot compare failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00200000 ${atln_uboot_size}; then
            echo Final redundant U-Boot read passed.
        else
            echo ERROR: final redundant U-Boot read failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_uboot_size}; then
            echo Final redundant U-Boot compare passed.
        else
            echo ERROR: final redundant U-Boot compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-kernel.img; then
            echo Reloaded kernel for final verification.
        else
            echo ERROR: could not reload kernel for final verification.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00300000 ${atln_kernel_size}; then
            echo Final kernel read passed.
        else
            echo ERROR: final kernel read failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_kernel_size}; then
            echo Final kernel compare passed.
        else
            echo ERROR: final kernel compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-initrd.img; then
            echo Reloaded initramfs for final verification.
        else
            echo ERROR: could not reload initramfs for final verification.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00C00000 ${atln_initrd_size}; then
            echo Final initramfs read passed.
        else
            echo ERROR: final initramfs read failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_initrd_size}; then
            echo Final initramfs compare passed.
        else
            echo ERROR: final initramfs compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        if fatload mmc 0:1 0x08000000 atln-dtb.bin; then
            echo Reloaded DTB for final verification.
        else
            echo ERROR: could not reload DTB for final verification.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if nand read 0x09000000 0x00F00000 ${atln_dtb_size}; then
            echo Final DTB read passed.
        else
            echo ERROR: final DTB read failed.
            setenv atln_stage_ok 0
        fi
    fi
    if test "${atln_stage_ok}" = "1"; then
        if cmp.b 0x08000000 0x09000000 ${atln_dtb_size}; then
            echo Final DTB compare passed.
        else
            echo ERROR: final DTB compare failed.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "1"; then
        mw.b 0x0A000000 0x4f 1
        if fatwrite mmc 0:1 0x0A000000 atln-stage.done 1; then
            echo NAND raw boot area passed final verification.
        else
            echo ERROR: could not persist NAND-stage completion marker.
            setenv atln_stage_ok 0
        fi
    fi

    if test "${atln_stage_ok}" = "0"; then
        echo ERROR: NAND raw boot stage failed; keep jumper in SD mode.
    fi
fi
EOF_STAGE

# Keep unsupported shell chaining out of the generated U-Boot script.
if grep -Fq '&&' "$stage_txt"; then
  echo 'generated NAND U-Boot stage contains unsupported && chaining' >&2
  exit 2
fi
mkimage -A arm -T script -C none -n 'AtlANTian NAND raw boot installer stage' -d "$stage_txt" "$OUTDIR/nand-stage.scr"

python3 - "$OUTDIR" "$root_lebs" "$root_volume_bytes" "$root_image_bytes" "$total_pebs" "$min_overlay_lebs" \
  "$ATLANTIAN_NAND_ROOTFS_BLOCK_BYTES" "$ATLANTIAN_NAND_ROOTFS_ZSTD_LEVEL" <<'PY'
import hashlib, json, os, sys
out, root_lebs, root_bytes, root_image_bytes, total_pebs, min_overlay, block_bytes, zstd_level = sys.argv[1:]
root_lebs, root_bytes, root_image_bytes, total_pebs, min_overlay, block_bytes, zstd_level = map(
    int, (root_lebs, root_bytes, root_image_bytes, total_pebs, min_overlay, block_bytes, zstd_level))
def digest(name):
    h=hashlib.sha256()
    with open(os.path.join(out,name),'rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()
files=("rootfs.squashfs","BOOT.bin","u-boot.img","spl-redundant.bin","uImage","uInitrd","devicetree.dtb","nand-stage.scr")
layout={
 "schema_version":1,"product":"atlantian-nand","release":os.environ["ATLANTIAN_VERSION"],
 "compression":{"rootfs_squashfs":"zstd","rootfs_zstd_level":zstd_level,"overlay_ubifs":"lzo","initramfs":"gzip-one-shot"},
 "ecc":{"raw_boot":"Micron on-die BCH 4/512 via BootROM/U-Boot","ubi_data":"Micron on-die BCH 4/512 via Linux"},
 "nand":{"total_bytes":268435456,"erase_bytes":131072,"page_bytes":2048,"oob_bytes":64,
         "boot_bytes":16777216,"ubi_offset_bytes":16777216,"ubi_pebs":total_pebs,"leb_bytes":126976,"ci_bad_peb_reserve":32},
 "volumes":{"rootfs":{"type":"static","filesystem":"squashfs","lebs":root_lebs,"bytes":root_bytes,
                        "image_bytes":root_image_bytes,"block_bytes":block_bytes,"mount":"ro,ubiblock"},
            "overlay":{"type":"dynamic","filesystem":"ubifs","autoresize":False,"allocation":"maximum-available-at-install","minimum_lebs":min_overlay,"mount":"rw,noatime,compr=lzo"}},
 "boot":{"spl_area_bytes":1048576,"uboot_primary_offset":1048576,"uboot_redund_offset":2097152,
         "kernel_offset":3145728,"kernel_slot_bytes":9437184,"initrd_offset":12582912,"initrd_slot_bytes":3145728,
         "dtb_offset":15728640,"dtb_slot_bytes":1048576},
 "files":{}}
for name in files:
    p=os.path.join(out,name); layout["files"][name]={"bytes":os.path.getsize(p),"sha256":digest(name)}
with open(os.path.join(out,"NAND-MANIFEST.json"),'w',encoding='utf-8') as f: json.dump(layout,f,indent=2,sort_keys=True); f.write('\n')
PY

(cd "$OUTDIR" && sha256sum BOOT.bin u-boot.img spl-redundant.bin uImage uInitrd devicetree.dtb nand-stage.scr rootfs.squashfs NAND-MANIFEST.json >SHA256SUMS)
rm -f "$PUBLIC"
tar -C "$OUTDIR" --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -I 'zstd -T0 -3' -cf "$PUBLIC" .

echo "Created NAND bundle: $PUBLIC"
echo "  raw boot reserve: ${ATLANTIAN_NAND_BOOT_MIB} MiB"
echo "  rootfs SquashFS image: $root_image_bytes bytes; static UBI volume: $root_lebs LEBs ($root_volume_bytes bytes)"
echo "  immutable compression: zstd level ${ATLANTIAN_NAND_ROOTFS_ZSTD_LEVEL}; writable UBIFS compression: lzo"
echo "  minimum internal overlay reserve: $min_overlay_lebs LEBs"
