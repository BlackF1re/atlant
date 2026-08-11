#!/bin/sh
# /init for AtlANTian for NAND. Keep this POSIX/busybox-compatible.
set -eu

PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PATH

panic_shell() {
    echo
    echo "AtlANTian NAND early boot failed: $*" >&2
    echo "Starting an emergency shell on ttyPS0." >&2
    exec /bin/busybox sh
}

mkdir -p /proc /sys /dev /run /newroot
mount -t proc proc /proc || panic_shell "cannot mount proc"
mount -t sysfs sysfs /sys || panic_shell "cannot mount sysfs"
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox mdev -s 2>/dev/null || true
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run || panic_shell "cannot mount /run"
mkdir -p /run/atlantian/lower /run/atlantian/internal-overlay /run/atlantian/external-overlay

# The kernel command line creates a named MTD partition for the UBI area. Do not
# guess mtd numbers: the raw boot partition and bad-block layout make that unsafe.
mtd=$(awk -F: '$2 ~ /"atlantian-ubi"/ {gsub(/[[:space:]]/, "", $1); print $1; found++} END {if (found != 1) exit 1}' /proc/mtd 2>/dev/null) \
    || panic_shell "expected exactly one MTD partition named atlantian-ubi"
[ -c "/dev/$mtd" ] || /bin/busybox mdev -s 2>/dev/null || true
[ -c "/dev/$mtd" ] || panic_shell "missing /dev/$mtd"

if [ ! -d /sys/class/ubi/ubi0 ]; then
    /sbin/ubiattach -p "/dev/$mtd" >/dev/console 2>&1 \
        || panic_shell "ubiattach failed for /dev/$mtd"
fi
/bin/busybox mdev -s 2>/dev/null || true

# The immutable Debian lower is a compressed SquashFS stored in a static UBI
# volume. Find it by volume name, create a read-only ubiblock device, then mount it.
root_vol=
for d in /sys/class/ubi/ubi0_*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = rootfs ] || continue
    [ -z "$root_vol" ] || panic_shell "multiple UBI volumes named rootfs"
    root_vol=${d##*/}
done
[ -n "$root_vol" ] || panic_shell "missing UBI rootfs volume"
[ "$(cat "/sys/class/ubi/$root_vol/type" 2>/dev/null || true)" = static ] \
    || panic_shell "rootfs UBI volume is not static"
/sbin/ubiblock --create "/dev/$root_vol" >/dev/console 2>&1 \
    || panic_shell "cannot create ubiblock for $root_vol"
/bin/busybox mdev -s 2>/dev/null || true
root_block=/dev/ubiblock${root_vol#ubi}
[ -b "$root_block" ] || panic_shell "missing $root_block"
mount -t squashfs -o ro,nodev "$root_block" /run/atlantian/lower \
    || panic_shell "cannot mount read-only SquashFS rootfs"

# UBI owns bad-block handling and wear-leveling for the writable data area.
mount -t ubifs -o rw,noatime,compr=lzo ubi0:overlay /run/atlantian/internal-overlay \
    || panic_shell "cannot mount internal overlay UBIFS"
mkdir -p /run/atlantian/internal-overlay/upper /run/atlantian/internal-overlay/work

upper=/run/atlantian/internal-overlay/upper
work=/run/atlantian/internal-overlay/work
mode=internal

# An SD card becomes the writable layer only after explicit token-based adoption.
internal_token=/run/atlantian/internal-overlay/.extroot-token
external_layout=none
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -b /dev/mmcblk0p2 ] && break
    /bin/busybox mdev -s 2>/dev/null || true
    sleep 0.25
done
if [ -s "$internal_token" ] && [ -b /dev/mmcblk0p2 ]; then
    if mount -t ext4 -o rw,noatime /dev/mmcblk0p2 /run/atlantian/external-overlay 2>/dev/null; then
        external_root=/run/atlantian/external-overlay/.atlantian-extroot
        external_token=$external_root/token
        if [ -s "$external_token" ] && [ "$(cat "$external_token")" = "$(cat "$internal_token")" ]; then
            mkdir -p "$external_root/upper" "$external_root/work"
            upper=$external_root/upper
            work=$external_root/work
            mode=external
            external_layout=recovery-p2
        else
            umount /run/atlantian/external-overlay || true
        fi
    fi
fi

mount -t overlay overlay -o "lowerdir=/run/atlantian/lower,upperdir=$upper,workdir=$work" /newroot \
    || panic_shell "cannot assemble OverlayFS root"

mkdir -p /newroot/run /newroot/proc /newroot/sys /newroot/dev
printf 'nand\n' > /run/atlantian/storage-edition
printf '%s\n' "$mode" > /run/atlantian/overlay-mode
printf '%s\n' "$mtd" > /run/atlantian/ubi-mtd
printf '%s\n' "$external_layout" > /run/atlantian/external-overlay-layout
printf '%s\n' "$root_vol" > /run/atlantian/rootfs-ubi-volume

mount --move /run /newroot/run || panic_shell "cannot move /run"
mount --move /proc /newroot/proc || panic_shell "cannot move /proc"
mount --move /sys /newroot/sys || panic_shell "cannot move /sys"
mount --move /dev /newroot/dev 2>/dev/null || true

exec /bin/busybox switch_root /newroot /sbin/init
