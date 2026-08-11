#!/usr/bin/env bash
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${1:?usage: install-runtime-policy.sh ROOTFS}
[[ -d $ROOT/etc/apt && -d $ROOT/usr/lib/systemd/system ]] || {
  echo "invalid AtlANTian rootfs: $ROOT" >&2
  exit 2
}

install -D -m 0644 "$PROJECT/config/apt-volatile.conf" \
  "$ROOT/etc/apt/apt.conf.d/10atlantian-volatile"
install -D -m 0644 "$PROJECT/systemd/run-apt.mount" \
  "$ROOT/usr/lib/systemd/system/run-apt.mount"
install -D -m 0644 "$PROJECT/systemd/atlantian-apt-tmpfiles.conf" \
  "$ROOT/usr/lib/tmpfiles.d/atlantian-apt.conf"

# Enable the mount by filesystem layout rather than invoking systemctl in a
# build chroot. systemd-tmpfiles-setup runs after local filesystems, so the
# partial directories are created inside the mounted tmpfs on every boot.
install -d -m 0755 "$ROOT/etc/systemd/system/local-fs.target.wants"
ln -sfn /usr/lib/systemd/system/run-apt.mount \
  "$ROOT/etc/systemd/system/local-fs.target.wants/run-apt.mount"
