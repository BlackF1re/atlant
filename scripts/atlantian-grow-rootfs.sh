#!/bin/sh
# First boot only: make p2 consume the rest of the inserted SD card.  A
# partition-table reread needs one reboot; resize2fs runs on the following boot.
set -eu
disk=/dev/mmcblk0 part=/dev/mmcblk0p2 state=/var/lib/atlantian/rootfs-grow
[ -b "$part" ] || exit 0
mkdir -p "$state"
ss=$(blockdev --getss "$disk"); diskbytes=$(blockdev --getsize64 "$disk")
start=$(cat /sys/class/block/mmcblk0p2/start); sectors=$(cat /sys/class/block/mmcblk0p2/size)
end=$(( (start + sectors) * ss ))
if [ "$end" -lt "$diskbytes" ]; then
  printf ',+\n' | sfdisk --no-reread --force -N 2 "$disk"
  : >"$state/resize-pending"; sync; systemctl --no-block reboot; exit 0
fi
if [ -e "$state/resize-pending" ] || [ ! -e "$state/done" ]; then
  resize2fs "$part"; rm -f "$state/resize-pending"; : >"$state/done"
fi
