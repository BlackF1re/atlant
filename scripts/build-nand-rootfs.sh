#!/usr/bin/env bash
# Derive the NAND edition from the already-built common Debian rootfs. This
# keeps SD and NAND on one userspace while avoiding a second full debootstrap
# and package installation pass. NAND-only additions remain explicit.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
. "$PROJECT/config/release.env"
. "$PROJECT/config/debian-snapshot.env"
[ -r "$PROJECT/config/local.env" ] && . "$PROJECT/config/local.env"
ROOT=${ROOT:-$PROJECT/out/rootfs-nand}
BASE_ROOT=${ATLANTIAN_BASE_ROOTFS:-$PROJECT/out/rootfs}
COMMON_PACKAGES=$PROJECT/config/packages.base
NAND_PACKAGES=$PROJECT/config/packages.nand
BASE_PACKAGE_LIST=${ATLANTIAN_PACKAGE_LIST:-$COMMON_PACKAGES}
SUITE=${SUITE:-$DEBIAN_CODENAME}
MIRROR=${MIRROR:-$DEBIAN_SNAPSHOT_MIRROR}

if [[ ${EUID} -ne 0 ]]; then exec sudo -E "$0" "$@"; fi
[[ -s $COMMON_PACKAGES && -s $NAND_PACKAGES ]] || { echo 'package profile missing' >&2; exit 2; }
[[ $(readlink -m "$BASE_ROOT") != $(readlink -m "$ROOT") ]] || {
  echo 'NAND rootfs destination must differ from the common rootfs' >&2; exit 2;
}

# Preserve standalone usability of this helper. In the normal build graph the
# common rootfs already exists, so this path is skipped and Debian is built once.
if [[ ! -d $BASE_ROOT/etc || ! -x $BASE_ROOT/bin/sh ]]; then
  ROOT="$BASE_ROOT" ATLANTIAN_PACKAGE_LIST="$BASE_PACKAGE_LIST" bash "$PROJECT/scripts/build-rootfs.sh"
fi

rm -rf "$ROOT"
mkdir -p "$ROOT"
rsync -aHAX --numeric-ids "$BASE_ROOT/" "$ROOT/"
install -D -m 0644 "$COMMON_PACKAGES" "$ROOT/usr/local/share/atlantian/packages.base"
install -D -m 0644 "$NAND_PACKAGES" "$ROOT/usr/local/share/atlantian/packages.nand"

# The common rootfs intentionally leaves Snapshot at the factory-build
# boundary. Switch the clone back to the exact same immutable Snapshot only
# while installing the tiny NAND-only package delta, then restore live runtime
# repositories. A regular resolver file is needed while systemd-resolved is not
# running inside the build chroot.
cat >"$ROOT/etc/apt/sources.list" <<EOF_SNAPSHOT_APT
deb [check-valid-until=no] $MIRROR $SUITE main non-free-firmware
deb [check-valid-until=no] $MIRROR ${SUITE}-updates main non-free-firmware
deb [check-valid-until=no] $DEBIAN_SECURITY_SNAPSHOT_MIRROR ${SUITE}-security main non-free-firmware
EOF_SNAPSHOT_APT
rm -f "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"

mount --bind /dev "$ROOT/dev"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
cleanup() {
  set +e
  mountpoint -q "$ROOT/sys" && umount -l "$ROOT/sys"
  mountpoint -q "$ROOT/proc" && umount -l "$ROOT/proc"
  mountpoint -q "$ROOT/dev" && umount -l "$ROOT/dev"
}
trap cleanup EXIT

chroot "$ROOT" /bin/bash -eux <<'EOF_CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' /usr/local/share/atlantian/packages.nand \
  | xargs -r apt-get install -y --no-install-recommends
apt-get clean
rm -rf /var/lib/apt/lists/*
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
EOF_CHROOT
install -m 0644 "$ROOT/usr/lib/atlantian/runtime-sources.list" "$ROOT/etc/apt/sources.list"

install -d -m 0755 "$ROOT/usr/lib/atlantian"
printf 'nand\n' >"$ROOT/usr/lib/atlantian/storage-edition"

# The NAND root is assembled by the early initramfs: static UBI -> ubiblock ->
# read-only SquashFS lower, plus an internal UBIFS or adopted-SD writable upper.
# /tmp and logs are volatile to avoid pointless raw-flash write amplification.
cat >"$ROOT/etc/fstab" <<'EOF_FSTAB'
# AtlANTian for NAND: / is assembled by initramfs from SquashFS + OverlayFS.
tmpfs /tmp tmpfs rw,nosuid,nodev,noatime,mode=1777,size=64M 0 0
EOF_FSTAB
chroot "$ROOT" systemctl disable atlantian-grow-rootfs.service >/dev/null 2>&1 || true

install -d -m 0755 "$ROOT/etc/systemd/journald.conf.d"
cat >"$ROOT/etc/systemd/journald.conf.d/atlantian-nand.conf" <<'EOF_JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF_JOURNAL

# Re-record the final package manifest so the NAND artifact describes exactly
# the common profile plus its tiny NAND-only addition.
chroot "$ROOT" /usr/bin/dpkg-query -W -f='${binary:Package}\t${Version}\n' \
  | LC_ALL=C sort >"$ROOT/usr/share/atlantian/debian-package-manifest.tsv"

cleanup
trap - EXIT
echo "NAND rootfs created from common rootfs: $ROOT ($(du -sm --apparent-size "$ROOT" | awk '{print $1}') MiB apparent before SquashFS compression)"
