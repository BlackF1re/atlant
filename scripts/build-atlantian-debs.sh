#!/usr/bin/env bash
# Package AtlANTian-owned files. Debian userspace remains maintained by normal
# live APT repositories; the immutable Snapshot is only a factory-build input.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/config/release.env"
. "$ROOT/config/atlantian-releases.conf"
OUT=${OUT:-$ROOT/artifacts/current}
RFS=${RFS:-$ROOT/out/rootfs}
RELEASE_VERSION=${ATLANTIAN_VERSION:?}
PACKAGE_VERSION=${ATLANTIAN_DEB_VERSION:?}
RELEASE_REPOSITORY=${ATLANTIAN_GITHUB_REPO:?}

mkdir -p "$OUT"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

control() {
  mkdir -p "$1/DEBIAN"
  cat >"$1/DEBIAN/control" <<EOF_CONTROL
Package: $2
Version: $PACKAGE_VERSION
Architecture: $3
Section: admin
Priority: optional
Maintainer: AtlANTian
Homepage: https://github.com/$RELEASE_REPOSITORY
Description: $4
EOF_CONTROL
}
conffiles() {
  [ -d "$1/etc" ] && find "$1/etc" -type f -printf '/etc/%P\n' >"$1/DEBIAN/conffiles" || true
}
copy() {
  local path=$1 target=$2
  mkdir -p "$target/$(dirname "$path")"
  cp -a "$RFS/$path" "$target/$path"
}

# Cross-major package installation is an explicit transaction. This preinst
# gate is embedded in every AtlANTian package so a package transaction cannot
# accidentally cross Debian generations outside atlantian-sysupgrade.
major_guard() {
  local package_root=$1
  cat >"$package_root/DEBIAN/preinst" <<'EOF_GUARD'
#!/bin/sh
set -eu
target_version='@TARGET_VERSION@'
target_major='@TARGET_MAJOR@'
authorization=/run/atlantian-major-upgrade-authorized

installed_version=$(cat /usr/lib/atlantian/version 2>/dev/null || true)
installed_major=${installed_version%%.*}
case "$installed_major" in
  ''|*[!0-9]*) exit 0 ;;
esac

if [ "$target_major" -lt "$installed_major" ]; then
  echo "refusing AtlANTian Debian-major downgrade: $installed_major -> $target_major" >&2
  exit 78
fi
if [ "$target_major" -gt "$installed_major" ]; then
  [ "$target_major" -eq $((installed_major + 1)) ] || {
    echo "refusing AtlANTian Debian-major skip: $installed_major -> $target_major" >&2
    exit 78
  }
  [ -r "$authorization" ] && [ "$(cat "$authorization")" = "$target_version" ] || {
    echo "Debian-major package transition to $target_version requires atlantian-sysupgrade" >&2
    exit 78
  }
fi
exit 0
EOF_GUARD
  sed -i \
    -e "s/@TARGET_VERSION@/$RELEASE_VERSION/g" \
    -e "s/@TARGET_MAJOR@/$DEBIAN_MAJOR/g" \
    "$package_root/DEBIAN/preinst"
  chmod 0755 "$package_root/DEBIAN/preinst"
}

# atlantian-kernel is an SD-layout package. A NAND system has no FAT boot
# partition and must update its raw boot region + SquashFS base through the NAND
# maintenance installer.
nand_kernel_guard() {
  local package_root=$1
  sed -i '/^exit 0$/i\
edition=$(cat /usr/lib/atlantian/storage-edition 2>/dev/null || echo sd)\
if [ "$edition" = nand ]; then\
  echo "atlantian-kernel cannot update a live NAND edition; run atlantian-sysupgrade from NAND to stage verified maintenance on the paired recovery SD" >&2\
  exit 78\
fi\
' "$package_root/DEBIAN/preinst"
}

p="$work/platform"
mkdir -p "$p"
control "$p" atlantian-platform all 'AtlANTian platform policy and tooling'
printf '%s\n' 'Depends: zram-tools' >>"$p/DEBIAN/control"

# /etc/apt/sources.list is user-owned. The managed template lives in
# /usr/lib/atlantian and is installed only when the runtime file is absent.
for f in \
  etc/atlantian/releases.conf \
  etc/apt/apt.conf.d/10atlantian-volatile \
  etc/ssh/sshd_config.d/10-atlantian-access.conf \
  etc/systemd/network/10-atlantian-ethernet.link \
  etc/systemd/network/20-ethernet.network \
  etc/systemd/resolved.conf.d/atlantian.conf \
  etc/systemd/logind.conf.d/atlantian-power-policy.conf; do
  copy "$f" "$p"
done
for source in "$RFS"/usr/local/sbin/atlantian-*; do
  f=${source#"$RFS"/}
  copy "$f" "$p"
done
mkdir -p "$p/usr/lib/systemd/system"
cp -a "$RFS/usr/lib/systemd/system/atlantian-"*.service "$p/usr/lib/systemd/system/"
cp -a "$RFS/usr/lib/systemd/system/atlantian-"*.timer "$p/usr/lib/systemd/system/"
copy "usr/lib/systemd/system/run-apt.mount" "$p"
copy "usr/lib/tmpfiles.d/atlantian-apt.conf" "$p"
mkdir -p "$p/lib/firmware/atlantian" "$p/etc/atlantian" \
  "$p/usr/share/atlantian" "$p/usr/lib/atlantian"
cp -a "$RFS/lib/firmware/atlantian/." "$p/lib/firmware/atlantian/"
cp -a "$RFS/etc/atlantian/." "$p/etc/atlantian/"
cp -a "$RFS/usr/share/atlantian/." "$p/usr/share/atlantian/"
for f in version package-version source-revision debian-codename debian-major debian-snapshot release-repo os-release runtime-sources.list; do
  copy "usr/lib/atlantian/$f" "$p"
done

# The platform package carries the NAND-specific updater so edition policy stays
# correct even when the common platform package is installed on NAND.
install -m 0755 "$ROOT/scripts/atlantian-sysupgrade-nand.sh" \
  "$p/usr/lib/atlantian/atlantian-sysupgrade-nand"

conffiles "$p"
major_guard "$p"
cat >"$p/DEBIAN/postinst" <<'EOF_POSTINST'
#!/bin/sh
set -e

if [ -s /usr/lib/atlantian/os-release ]; then
  install -m 0644 /usr/lib/atlantian/os-release /etc/os-release
fi

systemctl daemon-reload || true

systemctl enable --now run-apt.mount >/dev/null 2>&1 || true
if command -v systemd-tmpfiles >/dev/null 2>&1; then
  systemd-tmpfiles --create /usr/lib/tmpfiles.d/atlantian-apt.conf || true
fi

install -d -m 0755 /etc/systemd/system/ssh.service.wants
ln -sfn /usr/lib/systemd/system/atlantian-ssh-hostkeys.service \
  /etc/systemd/system/ssh.service.wants/atlantian-ssh-hostkeys.service
systemctl enable --force atlantian-status-leds.service atlantian-fpga-status-leds.service \
  atlantian-release-check.timer || true
edition=$(cat /usr/lib/atlantian/storage-edition 2>/dev/null || echo sd)
if [ "$edition" = nand ]; then
  systemctl disable atlantian-grow-rootfs.service atlantian-nand-auto-resume.service >/dev/null 2>&1 || true
  systemctl enable --force atlantian-nand-reconcile.service >/dev/null 2>&1 || true
  if [ -x /usr/lib/atlantian/atlantian-sysupgrade-nand ]; then
    install -m 0755 /usr/lib/atlantian/atlantian-sysupgrade-nand \
      /usr/local/sbin/atlantian-sysupgrade
  fi
else
  systemctl disable atlantian-nand-reconcile.service >/dev/null 2>&1 || true
  systemctl enable --force atlantian-grow-rootfs.service atlantian-nand-auto-resume.service >/dev/null 2>&1 || true
fi

template=/usr/lib/atlantian/runtime-sources.list
if [ -s "$template" ] && [ ! -s /etc/apt/sources.list ]; then
  install -d -m 0755 /etc/apt
  install -m 0644 "$template" /etc/apt/sources.list
fi
EOF_POSTINST
chmod 0755 "$p/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$p" "$OUT/atlantian-platform_${PACKAGE_VERSION}_all.deb"

k="$work/kernel"
mkdir -p "$k"
control "$k" atlantian-kernel armhf 'AtlANTian kernel and transactional SD boot payload'
major_guard "$k"
nand_kernel_guard "$k"
mkdir -p "$k/usr/lib/atlantian/boot" "$k/lib/modules"
cp -a "$RFS/lib/modules/." "$k/lib/modules/"
BOOT_BIN="$ROOT/out/bootloader/BOOT.bin" \
UBOOT_IMG="$ROOT/out/bootloader/u-boot.img" \
DTB="$ROOT/out/boot/devicetree.dtb" \
ZIMAGE="$ROOT/out/boot/zImage" \
  bash "$ROOT/scripts/populate-boot-files.sh" "$k/usr/lib/atlantian/boot" package
install -m 0644 "$ROOT/out/boot/zImage" "$k/usr/lib/atlantian/boot/zImage"
cat >"$k/DEBIAN/postinst" <<'EOF_KERNEL_POST'
#!/bin/sh
# Power-loss-safe SD kernel transaction. Early BOOT.bin/u-boot.img stay on the
# known-good boot chain; only the checksummed kernel+DTB FIT slot is switched.
set -eu
source=/usr/lib/atlantian/boot
target=/boot
abi=$(cat "$source/atlantian-boot-abi")
fit="$source/atlantian.itb"
[ -d "$target" ] || { echo 'AtlANTian SD boot partition is not mounted at /boot' >&2; exit 1; }
[ -s "$fit" ] && [ -s "$source/boot.scr" ] || { echo 'AtlANTian boot package is incomplete' >&2; exit 1; }
case "$abi" in ''|*[!0-9]*) echo 'invalid AtlANTian boot ABI' >&2; exit 1;; esac

write_fit() {
  dest=$1
  rm -f "$target/.$dest.new"
  install -m 0644 "$fit" "$target/.$dest.new"
  cmp -s "$fit" "$target/.$dest.new" || { echo "FIT staging verification failed: $dest" >&2; exit 1; }
  sync
  mv -f "$target/.$dest.new" "$target/$dest"
  sync
}

# Migration from the historical uImage+DTB layout is itself ordered safely:
# both FIT slots land first, then boot.scr is atomically replaced. Until that
# final rename the old loader and old payload remain untouched and bootable.
if [ ! -s "$target/atlantian-A.itb" ] || [ ! -s "$target/atlantian-B.itb" ]; then
  write_fit atlantian-A.itb
  write_fit atlantian-B.itb
  install -m 0644 "$source/boot.scr" "$target/.boot.scr.new"
  cmp -s "$source/boot.scr" "$target/.boot.scr.new" || exit 1
  sync
  mv -f "$target/.boot.scr.new" "$target/boot.scr"
  printf '%s\n' "$abi" >"$target/.atlantian-boot-abi.new"
  sync
  mv -f "$target/.atlantian-boot-abi.new" "$target/atlantian-boot-abi"
  rm -f "$target/atlantian-slot-B"
  sync
  # Keep the historical uImage/DTB for one boot generation as an additional
  # migration fallback. A later normal slot transaction removes them.
  exit 0
fi

installed_abi=$(cat "$target/atlantian-boot-abi" 2>/dev/null || true)
[ "$installed_abi" = "$abi" ] || {
  echo "online boot-loader ABI migration is unsupported ($installed_abi -> $abi); reflash the SD image" >&2
  exit 78
}
cmp -s "$source/boot.scr" "$target/boot.scr" || {
  echo 'online boot.scr replacement is intentionally blocked; reflash is required for a boot-loader ABI change' >&2
  exit 78
}

if [ -e "$target/atlantian-slot-B" ]; then
  inactive=atlantian-A.itb
  next=A
else
  inactive=atlantian-B.itb
  next=B
fi
write_fit "$inactive"

# The slot marker is the transaction commit record. FAT rename/unlink is one
# directory-entry operation; every large payload write has already been synced.
if [ "$next" = B ]; then
  printf 'B\n' >"$target/.atlantian-slot-B.new"
  sync
  mv -f "$target/.atlantian-slot-B.new" "$target/atlantian-slot-B"
else
  rm -f "$target/atlantian-slot-B"
fi
sync

# Legacy files are no longer part of the active or rollback boot path once a
# normal A/B transaction has completed.
rm -f "$target/uImage" "$target/devicetree.dtb" \
  "$target/.uImage.new" "$target/.devicetree.dtb.new" "$target/.atlantian-slot-B.new"
sync
EOF_KERNEL_POST
chmod 0755 "$k/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$k" "$OUT/atlantian-kernel_${PACKAGE_VERSION}_armhf.deb"

r="$work/release"
mkdir -p "$r"
control "$r" atlantian-release all 'AtlANTian release meta-package'
major_guard "$r"
printf 'Depends: atlantian-platform (= %s), atlantian-kernel (= %s)\n' \
  "$PACKAGE_VERSION" "$PACKAGE_VERSION" >>"$r/DEBIAN/control"
dpkg-deb --build --root-owner-group "$r" "$OUT/atlantian-release_${PACKAGE_VERSION}_all.deb"
