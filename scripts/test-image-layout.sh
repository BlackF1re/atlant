#!/usr/bin/env bash
set -euo pipefail

IMAGE=${1:?image path required}
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJECT/config/image-layout.env"
. "$PROJECT/config/release.env"
LOOP= BOOT= ROOT= WORK=$(mktemp -d)
cleanup() { set +e; [ -n "${BOOT:-}" ] && mountpoint -q "$BOOT" && umount "$BOOT"; [ -n "${ROOT:-}" ] && mountpoint -q "$ROOT" && umount "$ROOT"; [ -n "${LOOP:-}" ] && losetup -d "$LOOP"; rm -rf "$WORK"; }
trap cleanup EXIT

partition_table=$WORK/partition-table.txt
sfdisk -d "$IMAGE" >"$partition_table"
grep -q 'label: dos' "$partition_table"
[ "$(grep -Ec '^.*\.img[0-9]+' "$partition_table")" = 2 ]
LOOP=$(losetup --find --show --partscan "$IMAGE"); sleep 1
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && [ ! -b "${LOOP}p3" ]
[ "$(blkid -o value -s TYPE "${LOOP}p1")" = vfat ]
[ "$(blkid -o value -s TYPE "${LOOP}p2")" = ext4 ]
[ "$(blkid -o value -s LABEL "${LOOP}p1")" = BOOT ]
[ "$(blkid -o value -s LABEL "${LOOP}p2")" = atlantian-root ]
[ "$(blockdev --getsize64 "${LOOP}p1")" = $((ATLANTIAN_BOOT_MIB * 1024 * 1024)) ]

BOOT=$WORK/boot; ROOT=$WORK/root; mkdir -p "$BOOT" "$ROOT"
mount -o ro "${LOOP}p1" "$BOOT"; mount -o ro "${LOOP}p2" "$ROOT"
for f in BOOT.bin u-boot.img boot.scr uEnv.txt atlantian-A.itb atlantian-B.itb atlantian-boot-abi; do
  [ -s "$BOOT/$f" ] || { echo "missing boot asset: $f" >&2; exit 3; }
done
[ "$(cat "$BOOT/atlantian-boot-abi")" = 1 ]
[ ! -e "$BOOT/atlantian-slot-B" ] || { echo 'factory image must start from FIT slot A' >&2; exit 3; }
for legacy in zImage uImage devicetree.dtb; do
  [ ! -e "$BOOT/$legacy" ] || { echo "legacy SD boot asset must not be present: $legacy" >&2; exit 3; }
done
cmp "$BOOT/atlantian-A.itb" "$BOOT/atlantian-B.itb"

# The image must never cap RAM from the Linux command line. The DT carries the
# 1 GiB S9 probe ceiling; source-built U-Boot probes DDR and fixes /memory.
boot_script_strings=$WORK/boot-script.strings
strings "$BOOT/boot.scr" >"$boot_script_strings"
! grep -Eq '(^|[[:space:]])mem=[^[:space:]]+' "$BOOT/uEnv.txt"
! grep -Eq '(^|[[:space:]])mem=[^[:space:]]+' "$boot_script_strings"
grep -Fq 'atlantian_normal_bootargs=console=ttyPS0,115200n8 root=/dev/mmcblk0p2' "$BOOT/uEnv.txt"
grep -Fq 'root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait' "$boot_script_strings"
grep -Fq 'atlantian-slot-B' "$boot_script_strings"
grep -Fq 'atlantian-A.itb' "$boot_script_strings"
grep -Fq 'atlantian-B.itb' "$boot_script_strings"
grep -Fq 'bootm 0x02000000' "$boot_script_strings"
mkimage -l "$BOOT/boot.scr" >"$WORK/boot-script.info"
mkimage -l "$BOOT/atlantian-A.itb" >"$WORK/fit.info"
grep -q 'Script' "$WORK/boot-script.info"
grep -q 'FIT description' "$WORK/fit.info"
grep -q 'Hash algo:.*sha256' "$WORK/fit.info"
dumpimage -T flat_dt -p 1 -o "$WORK/devicetree.dtb" "$BOOT/atlantian-A.itb" >/dev/null
[ "$(fdtget -t x "$WORK/devicetree.dtb" /memory@0 reg)" = '0 40000000' ] || {
  echo 'FIT device tree no longer exposes the 1 GiB DDR probe ceiling' >&2
  exit 3
}

for f in etc/fstab etc/apt/sources.list etc/systemd/network/10-atlantian-ethernet.link \
  usr/lib/atlantian/version usr/lib/atlantian/debian-major usr/lib/atlantian/debian-codename usr/lib/atlantian/runtime-sources.list \
  usr/local/sbin/atlantian-grow-rootfs usr/local/sbin/atlantian-sysupgrade usr/local/sbin/atlantian-release-check; do
  [ -e "$ROOT/$f" ] || { echo "missing root contract: $f" >&2; exit 3; }
done

grep -qx '/dev/mmcblk0p2 / ext4 defaults 0 1' "$ROOT/etc/fstab"
grep -qx '/dev/mmcblk0p1 /boot vfat defaults 0 2' "$ROOT/etc/fstab"
! grep -q mmcblk0p3 "$ROOT/etc/fstab"
[ "$(cat "$ROOT/usr/lib/atlantian/version")" = "$ATLANTIAN_VERSION" ]
[ "$(cat "$ROOT/usr/lib/atlantian/debian-major")" = "$DEBIAN_MAJOR" ]
[ "$(cat "$ROOT/usr/lib/atlantian/debian-codename")" = "$DEBIAN_CODENAME" ]
cmp "$ROOT/etc/apt/sources.list" "$ROOT/usr/lib/atlantian/runtime-sources.list"
! grep -q 'snapshot.debian.org' "$ROOT/etc/apt/sources.list"
grep -qx 'MACAddressPolicy=persistent' "$ROOT/etc/systemd/network/10-atlantian-ethernet.link"

[ -e "$ROOT/etc/machine-id" ] && [ ! -s "$ROOT/etc/machine-id" ]
[ -z "$(find "$ROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*_key' -print -quit)" ]
[ -e "$ROOT/usr/lib/systemd/system/atlantian-ssh-hostkeys.service" ]
[ ! -e "$ROOT/etc/systemd/system/atlantian-ssh-hostkeys.service" ]
[ -L "$ROOT/etc/systemd/system/ssh.service.wants/atlantian-ssh-hostkeys.service" ]
[ "$(readlink "$ROOT/etc/systemd/system/ssh.service.wants/atlantian-ssh-hostkeys.service")" = /usr/lib/systemd/system/atlantian-ssh-hostkeys.service ]
[ -e "$ROOT/usr/lib/systemd/system/atlantian-grow-rootfs.service" ]
[ -e "$ROOT/usr/lib/systemd/system/atlantian-nand-auto-resume.service" ]
[ -e "$ROOT/usr/lib/systemd/system/atlantian-nand-reconcile.service" ]
[ -z "$(find "$ROOT/etc/systemd/system" -maxdepth 1 -type f \( -name 'atlantian-*.service' -o -name 'atlantian-*.timer' \) -print -quit)" ]
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/atlantian-grow-rootfs.service" ]
[ "$(stat -c %u "$ROOT")" = 0 ]; [ "$(stat -c %u "$ROOT/etc/shadow")" = 0 ]
if [ -n "${SUDO_UID:-}" ] && [ "$SUDO_UID" != 0 ]; then
  [ -z "$(find "$ROOT" -xdev -uid "$SUDO_UID" -print -quit)" ]
fi

echo 'two-partition image, transactional A/B FIT boot, dynamic DDR, vendor systemd units, live APT, Debian lifecycle, identity and ownership contracts passed'
