#!/usr/bin/env bash
# Report what consumes an assembled AtlANTian rootfs. Read-only.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS=${ROOTFS:-$PROJECT/out/rootfs}
[[ -d "$ROOTFS" ]] || { echo "missing rootfs: $ROOTFS" >&2; exit 2; }

echo '== rootfs top level (KiB) =='
du -x -k -d1 "$ROOTFS" | sort -n

echo '== installed kernel module groups (KiB) =='
du -k -d2 "$ROOTFS/lib/modules" 2>/dev/null | sort -n | tail -80

echo '== largest installed packages (Installed-Size KiB) =='
chroot "$ROOTFS" dpkg-query -W -f='${Installed-Size}\t${Package}\n' \
  | sort -n | tail -100

echo '== removable documentation/locale payload (KiB) =='
for path in usr/share/doc usr/share/man usr/share/info usr/share/locale; do
  du -sk "$ROOTFS/$path" 2>/dev/null || true
done

echo '== largest kernel modules (bytes) =='
find "$ROOTFS/lib/modules" -type f -name '*.ko*' -printf '%s\t%p\n' \
  | sort -nr | head -100
