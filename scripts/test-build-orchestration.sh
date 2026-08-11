#!/usr/bin/env bash
# Cheap static contracts for the build graph. Run before rootfs/kernel work so a
# shell invocation or ordering regression cannot waste a full production run.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { echo "build orchestration contract: $*" >&2; exit 1; }
require() {
  local needle=$1 file=$2
  grep -Fq -- "$needle" "$file" || fail "$file is missing: $needle"
}

# Package profiles are human-readable source files. Every non-comment entry must
# remain a single package token.
require "sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d'" scripts/build-rootfs.sh
validate_package_profile() {
  local file=$1 package count=0
  while IFS= read -r package; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]] \
      || fail "$file contains an invalid package token after comment filtering: [$package]"
    count=$((count + 1))
  done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$file")
  (( count > 0 )) || fail "$file contains no installable package tokens"
}
validate_package_profile config/packages.base
validate_package_profile config/packages.nand

# NAND derives from the exact common factory rootfs and adds only its explicit
# early-boot package delta. A normal full build must never run debootstrap twice.
require 'ARCH=armhf' scripts/build-rootfs.sh
require 'debootstrap --cache-dir="$CACHE_DIR" --arch="$ARCH"' scripts/build-rootfs.sh
require 'COMMON_PACKAGES=$PROJECT/config/packages.base' scripts/build-nand-rootfs.sh
require 'BASE_ROOT=${ATLANTIAN_BASE_ROOTFS:-$PROJECT/out/rootfs}' scripts/build-nand-rootfs.sh
require 'rsync -aHAX --numeric-ids "$BASE_ROOT/" "$ROOT/"' scripts/build-nand-rootfs.sh
require '/usr/local/share/atlantian/packages.nand' scripts/build-nand-rootfs.sh
require 'busybox-static' config/packages.nand

# Source-tree helpers may legitimately have Git mode 100644, so invoke them via
# explicit interpreters rather than depending on executable bits.
for needle in \
  'sudo -E bash "$ROOT/scripts/build-nand-rootfs.sh"' \
  'sudo bash "$ROOT/scripts/install-nand-tools.sh" "$ROOT/out/rootfs" sd' \
  'ROOTFS="$ROOT/out/rootfs-nand" OUT="$INITRAMFS" bash "$ROOT/scripts/build-nand-initramfs.sh"' \
  'bash "$ROOT/scripts/build-uboot.sh"' \
  'INITRAMFS="$INITRAMFS" bash "$ROOT/scripts/build-uboot-nand.sh"' \
  'bash "$ROOT/scripts/build-atlantian-debs.sh"' \
  'bash "$ROOT/scripts/build-nand-bundle.sh"' \
  'bash "$ROOT/scripts/embed-nand-bundle.sh"' \
  'bash "$ROOT/scripts/make-sd-image.sh"'; do
  require "$needle" scripts/build-incremental.sh
done
nand_clone_line=$(grep -nF 'sudo -E bash "$ROOT/scripts/build-nand-rootfs.sh"' scripts/build-incremental.sh | head -n1 | cut -d: -f1)
sd_specialize_line=$(grep -nF 'sudo bash "$ROOT/scripts/install-nand-tools.sh" "$ROOT/out/rootfs" sd' scripts/build-incremental.sh | head -n1 | cut -d: -f1)
(( nand_clone_line < sd_specialize_line )) || fail 'NAND must clone the common rootfs before SD-specific tooling is installed'
require 'bash "$ROOT/scripts/patch-uboot-nand.sh" "$SRC"' scripts/build-uboot.sh
require 'bash "$ROOT/scripts/patch-uboot-nand.sh" "$SRC" --spl-loader' scripts/build-uboot-nand.sh
require "select SPL_NAND_INIT" scripts/patch-uboot-nand.sh
require "select SPL_MTD" scripts/patch-uboot-nand.sh

# Cache invalidation must follow the data actually stored. Linux builds in-tree,
# so its object cache is keyed by every kernel product input and the cross
# toolchain. U-Boot cache holds source only. debootstrap cache holds downloads.
require 'key: linux-build-${{ steps.identity.outputs.kernel_commit }}-${{ steps.identity.outputs.kernel_localversion }}-${{ steps.toolchain.outputs.fingerprint }}-' .github/workflows/build-release.yml
require "hashFiles('board/zynq-bitmain-antminer-s9.dts', 'config/kernel.fragment', 'config/kernel-prune.fragment', 'kernel-overlay/**', 'scripts/build-kernel.sh')" .github/workflows/build-release.yml
require 'arm-linux-gnueabihf-gcc --version' .github/workflows/build-release.yml
require 'arm-linux-gnueabihf-ld --version' .github/workflows/build-release.yml
require 'key: uboot-source-${{ steps.identity.outputs.uboot_commit }}' .github/workflows/build-release.yml
require "key: debootstrap-\${{ steps.identity.outputs.debian_codename }}-\${{ hashFiles('config/debian-snapshot.env') }}" .github/workflows/build-release.yml
require 'git -C out/linux-src reset --quiet --hard "$ATLANTIAN_KERNEL_COMMIT"' .github/workflows/build-release.yml
require 'git -C "$SRC" reset --quiet --hard "$ATLANTIAN_UBOOT_COMMIT"' scripts/build-uboot.sh
require 'git -C "$SRC" reset --quiet --hard "$ATLANTIAN_UBOOT_COMMIT"' scripts/build-uboot-nand.sh

# The single SD image must contain the exact release-matched NAND bundle under
# the runtime path used by atlantian-nand-install.
require 'sudo rm -rf "$ROOTFS/usr/lib/atlantian/nand"' scripts/embed-nand-bundle.sh
require 'sudo cp -a "$BUNDLE/." "$ROOTFS/usr/lib/atlantian/nand/"' scripts/embed-nand-bundle.sh
require '(cd "$ROOTFS/usr/lib/atlantian/nand" && sha256sum -c SHA256SUMS' scripts/embed-nand-bundle.sh

# Automatic continuation must be enabled only for SD and remain gated by the
# persistent pending marker.
require 'ConditionPathExists=/var/lib/atlantian/nand-install/pending' systemd/atlantian-nand-auto-resume.service
require 'ExecStart=/usr/local/sbin/atlantian-nand-install --resume-auto' systemd/atlantian-nand-auto-resume.service
require 'atlantian-nand-auto-resume.service' scripts/install-nand-tools.sh

# A full NAND base update is a clean rebase. Capture compares the current merged
# view with its immutable lower; restore starts with fresh upper/work directories
# above the verified target lower. Package payloads come from the target base,
# while selected persistent state and package intent are replayed.
require 'atlantian-nand-rebase.sh' scripts/install-nand-tools.sh
require 'atlantian-nand-rebase capture' scripts/atlantian-nand-upgrade.sh
require 'atlantian-nand-rebase restore "$UPGRADE_SAVE/internal"' scripts/atlantian-nand-install.sh
require '--compare-dest=' scripts/atlantian-nand-rebase.sh
require 'manual-extra.packages' scripts/atlantian-nand-rebase.sh
require 'rebase_schema=1' scripts/atlantian-nand-upgrade.sh
require 'validate_rebase_snapshot' scripts/atlantian-nand-install.sh
require 'rm -rf /.atlantian-extroot/upper /.atlantian-extroot/work' scripts/atlantian-nand-install.sh
require 'sudo -E bash "$ROOT/scripts/test-nand-rebase.sh" "$ROOT/out/rootfs-nand"' scripts/test-build.sh
require 'stale-package-payload' scripts/test-nand-rebase.sh
require 'etc/debian_version' scripts/test-nand-rebase.sh
if grep -Fq 'full-upgrade' scripts/atlantian-nand-reconcile.sh; then
  fail 'rebased NAND reconcile must not copy the target base into upper via full-upgrade'
fi
if grep -Fq '$UPGRADE_SAVE/upper' scripts/atlantian-nand-install.sh scripts/atlantian-nand-upgrade.sh; then
  fail 'full NAND upgrade must not preserve or restore a complete upper'
fi

# The pinned upstream config script supports repeated commands in one invocation.
require '"$SRC/scripts/config" --file "$BUILD/.config" \' scripts/build-uboot.sh
require '"$SRC/scripts/config" --file "$BUILD/.config" \' scripts/build-uboot-nand.sh

# SPL_NAND_SUPPORT exposes SYS_NAND_BLOCK_SIZE as a mandatory value. Bind it to
# the known erase geometry and bound all sync work so CI cannot prompt forever.
require "printf -v nand_block_hex '0x%X' \"\$ATLANTIAN_NAND_ERASE_BYTES\"" scripts/build-uboot-nand.sh
require '--set-val SYS_NAND_BLOCK_SIZE "$nand_block_hex"' scripts/build-uboot-nand.sh
require 'CONFIG_SYS_NAND_BLOCK_SIZE=$nand_block_hex' scripts/build-uboot-nand.sh
require 'timeout 60s make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" olddefconfig </dev/null' scripts/build-uboot-nand.sh
require 'timeout 60s make -C "$SRC" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" prepare </dev/null' scripts/build-uboot-nand.sh
require 'CONFIG_XPL_BUILD=y' scripts/build-uboot-nand.sh
require 'CONFIG_SPL_BUILD=y' scripts/build-uboot-nand.sh
require 'CONFIG_SPL_NAND_INIT=y' scripts/build-uboot-nand.sh
require 'CONFIG_SPL_MTD=y' scripts/build-uboot-nand.sh
require "grep -Eq '^CONFIG_[A-Z0-9_]+=$' \"\$BUILD/.config\"" scripts/build-uboot-nand.sh

# NAND U-Boot compiles exact initramfs length into bootcmd. The authoritative
# initramfs must be built after final rootfs stamping and not regenerated later.
require 'stamp' scripts/build-incremental.sh
require 'nand_initramfs' scripts/build-incremental.sh
require 'INITRAMFS="$INITRAMFS" bash "$ROOT/scripts/build-uboot-nand.sh"' scripts/build-incremental.sh
require '[[ -s $INITRAMFS ]] || { echo "missing authoritative NAND initramfs:' scripts/build-incremental.sh

# The archive itself must be deterministic because its exact byte length is a
# bootloader contract.
require 'cpio --null --quiet --reproducible -o -H newc --owner=0:0' scripts/build-nand-initramfs.sh
require 'touch -h -d "@${SOURCE_DATE_EPOCH}"' scripts/build-nand-initramfs.sh

# Finished artifacts must verify exact raw read lengths and prove that the same
# NAND payload is actually inside the one public image.
require 'raw-boot-sizes.env' scripts/test-nand-artifacts.sh
require 'NAND U-Boot initrd read length mismatch' scripts/test-nand-artifacts.sh
require 'unified image does not contain the NAND payload' scripts/test-nand-artifacts.sh

# A source archive committed into a fresh repository is a supported first-class
# deployment path. Keep its GitHub identity and release-state behavior guarded by
# the same cheap preflight that protects the expensive build.
bash scripts/test-repository-portability.sh

echo 'build orchestration, clean NAND rebase + integration, exact build caches, unified image, boot-length and repository-portability contracts passed'
