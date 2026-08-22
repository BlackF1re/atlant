#!/usr/bin/env bash
# Fast, diagnostic repository contracts. These checks validate current
# safety/boot/update invariants before any expensive rootfs/kernel build.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { printf 'SOURCE CONTRACT FAILED: %s\n' "$*" >&2; exit 1; }
require_text() {
  local name=$1 pattern=$2
  shift 2
  grep -Fq -- "$pattern" "$@" || fail "$name: missing [$pattern] in $*"
}
require_regex() {
  local name=$1 pattern=$2
  shift 2
  grep -Eq -- "$pattern" "$@" || fail "$name: pattern [$pattern] not found in $*"
}
reject_text() {
  local name=$1 pattern=$2
  shift 2
  if grep -RFq --exclude=test-source-contracts.sh -- "$pattern" "$@"; then
    fail "$name: forbidden text [$pattern] found in $*"
  fi
}
reject_regex() {
  local name=$1 pattern=$2
  shift 2
  if grep -REq --exclude=test-source-contracts.sh -- "$pattern" "$@"; then
    fail "$name: forbidden pattern [$pattern] found in $*"
  fi
}

for file in scripts/*.sh; do
  shell=bash
  [[ $(head -n1 "$file") == '#!/bin/sh' ]] && shell=dash
  "$shell" -n "$file" || fail "shell syntax: $file does not parse with $shell"
done

. config/release.env
. config/debian-snapshot.env
. config/u-boot.env
. config/nand-layout.env

# Release identity and immutable source pins.
[[ $DEBIAN_CODENAME =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail 'release: invalid Debian codename'
[[ $DEBIAN_MAJOR =~ ^[0-9]+$ ]] || fail 'release: invalid Debian major'
[[ $ATLANTIAN_MINOR =~ ^[0-9]+$ ]] || fail 'release: AtlANTian minor must be numeric'
[[ $ATLANTIAN_PATCH =~ ^[0-9]+$ ]] || fail 'release: AtlANTian patch must be numeric'
[[ $ATLANTIAN_DEBIAN_REVISION =~ ^[1-9][0-9]*$ ]] || fail 'release: Debian package revision must be positive'
if [[ -n $ATLANTIAN_PRERELEASE ]]; then
  [[ $ATLANTIAN_PRERELEASE =~ ^[0-9A-Za-z]+([.-][0-9A-Za-z]+)*$ ]] || fail 'release: invalid prerelease identifier'
  expected_version="${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${ATLANTIAN_PATCH}-${ATLANTIAN_PRERELEASE}"
  expected_deb="${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${ATLANTIAN_PATCH}~${ATLANTIAN_PRERELEASE}-${ATLANTIAN_DEBIAN_REVISION}"
  dpkg --compare-versions "$expected_deb" lt "${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${ATLANTIAN_PATCH}-${ATLANTIAN_DEBIAN_REVISION}" \
    || fail 'release: Debian prerelease ordering is invalid'
else
  expected_version="${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${ATLANTIAN_PATCH}"
  expected_deb="${expected_version}-${ATLANTIAN_DEBIAN_REVISION}"
fi
[[ $ATLANTIAN_VERSION == "$expected_version" ]] || fail "release: expected $expected_version, got $ATLANTIAN_VERSION"
[[ $ATLANTIAN_DEB_VERSION == "$expected_deb" ]] || fail "release: expected package version $expected_deb, got $ATLANTIAN_DEB_VERSION"
[[ $ATLANTIAN_RELEASE_ID == "atlantian-$ATLANTIAN_VERSION" ]] || fail 'release: release ID must derive only from semantic version'
[[ $ATLANTIAN_IMAGE_NAME == "$ATLANTIAN_RELEASE_ID" ]] || fail 'release: image name must equal release identity'
[[ $DEBIAN_SNAPSHOT_TIMESTAMP =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail 'release: invalid Debian Snapshot timestamp'
[[ $ATLANTIAN_KERNEL_SERIES =~ ^[0-9]+\.[0-9]+$ ]] || fail 'release: kernel LTS series must be major.minor'
[[ $ATLANTIAN_KERNEL_VERSION == "$ATLANTIAN_KERNEL_SERIES".* ]] || fail 'release: kernel version left configured LTS series'
[[ $ATLANTIAN_KERNEL_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'release: kernel commit must be a full immutable SHA'
[[ $ATLANTIAN_KERNEL_LOCALVERSION =~ ^-atlantian[1-9][0-9]*$ ]] || fail 'release: kernel ABI suffix must be independent and numeric'
[[ $ATLANTIAN_UBOOT_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'release: U-Boot commit must be a full immutable SHA'
[[ $ATLANTIAN_UBOOT_DEFCONFIG == bitmain_antminer_s9_defconfig ]] || fail 'release: unexpected U-Boot defconfig'
require_text 'Debian-compatible os-release identity' 'ID=debian' scripts/stamp-release.sh
require_text 'AtlANTian os-release variant' 'VARIANT_ID=atlantian' scripts/stamp-release.sh
require_text 'Debian machine name' 'NAME="Debian GNU/Linux"' scripts/stamp-release.sh
require_text 'package-owned os-release payload' 'usr/lib/atlantian/os-release' scripts/build-atlantian-debs.sh
require_text 'Debian-safe package version' 'PACKAGE_VERSION=${ATLANTIAN_DEB_VERSION:?}' scripts/build-atlantian-debs.sh
require_text 'rootfs Debian architecture request' 'ARCH=armhf' scripts/build-rootfs.sh
require_text 'release-input Debian architecture validation' 'ARCH=armhf' scripts/validate-release-inputs.sh
require_text 'Debian watcher architecture validation' 'ARCH=armhf' scripts/refresh-debian-base.sh
require_text 'kernel Debian package architecture' 'control "$k" atlantian-kernel armhf' scripts/build-atlantian-debs.sh

# Debian lifecycle.
require_text 'Debian stable aliases' 'for alias in stable oldstable oldoldstable' scripts/refresh-debian-base.sh
require_text 'Debian major availability' 'major_available=true' scripts/refresh-debian-base.sh
require_text 'Debian major explicit transition' 'explicit AtlANTian release-line transition' scripts/refresh-debian-base.sh
require_text 'snapshot leaves release unchanged' 'AtlANTian remains $ATLANTIAN_VERSION' scripts/refresh-debian-base.sh
require_text 'watcher validates without publishing' 'gh workflow run build-release.yml --ref main -f publish=false' .github/workflows/debian-watch.yml
require_text 'generic debootstrap script' 'DEBOOTSTRAP_SCRIPT=/usr/share/debootstrap/scripts/sid' scripts/build-rootfs.sh
require_text 'snapshot package profile override' 'ATLANTIAN_PACKAGE_LIST' scripts/build-rootfs.sh scripts/build-nand-rootfs.sh
require_text 'shared NAND package base' 'COMMON_PACKAGES=$PROJECT/config/packages.base' scripts/build-nand-rootfs.sh
require_text 'live base repository' 'deb https://deb.debian.org/debian $SUITE main non-free-firmware' scripts/build-rootfs.sh
require_text 'live security repository' 'deb https://security.debian.org/debian-security ${SUITE}-security main non-free-firmware' scripts/build-rootfs.sh
require_text 'runtime repository payload' 'runtime-sources.list' scripts/build-rootfs.sh scripts/build-atlantian-debs.sh
require_text 'major upgrade authorization' 'atlantian-major-upgrade-authorized' scripts/atlantian-sysupgrade.sh scripts/build-atlantian-debs.sh
require_text 'major upgrade resume marker' 'major-upgrade-pending.env' scripts/atlantian-sysupgrade.sh scripts/atlantian-login-info.sh
require_text 'major upgrade resume function' 'resume_major_upgrade' scripts/atlantian-sysupgrade.sh
require_text 'major upgrade source backup' 'major-upgrade-sources-backup' scripts/atlantian-sysupgrade.sh
reject_text 'no sysupgrade downgrades' '--allow-downgrades' scripts/atlantian-sysupgrade.sh

# DDR and kernel memory policy.
for dts in board/zynq-bitmain-antminer-s9.dts board/uboot_bitmain-antminer-s9.dts; do
  require_text "DDR aperture $dts" 'reg = <0x0 0x40000000>;' "$dts"
done
require_text 'kernel HIGHMEM' 'CONFIG_HIGHMEM=y' config/kernel.fragment
require_text 'kernel Zynq/HIGHMEM generated-config gate' 'CONFIG_ARCH_ZYNQ CONFIG_HIGHMEM' scripts/build-kernel.sh
reject_regex 'no fixed Linux memory cap' '(^|[[:space:]])mem=(496M|512M|1008M|1024M)([[:space:]]|$)' \
  scripts/populate-boot-files.sh scripts/make-sd-image.sh board/zynq-bitmain-antminer-s9.dts board/uboot_bitmain-antminer-s9.dts

# SD/recovery U-Boot and transactional kernel/DT boot.
require_text 'U-Boot pin' 'ATLANTIAN_UBOOT_COMMIT=' config/u-boot.env
require_text 'SD SPL payload' "--set-str SPL_FS_LOAD_PAYLOAD_NAME 'u-boot.img'" scripts/build-uboot.sh
require_text 'SD U-Boot autoboot' "ATLANTIAN_BOOTCOMMAND='fatload mmc 0:1 0x03000000 boot.scr && source 0x03000000'" scripts/build-uboot.sh
require_text 'SD NAND command support' '--enable CMD_NAND' scripts/build-uboot.sh
require_text 'SD FAT write support' '--enable FAT_WRITE' scripts/build-uboot.sh
require_text 'SD immutable environment' '--enable ENV_IS_NOWHERE' scripts/build-uboot.sh
require_text 'SD no NAND environment' '--disable ENV_IS_IN_NAND' scripts/build-uboot.sh
require_text 'SD watchdog remains disarmed' '--disable WATCHDOG_AUTOSTART' scripts/build-uboot.sh
require_text 'SD FIT slot A' 'atlantian-A.itb' scripts/populate-boot-files.sh scripts/build-atlantian-debs.sh
require_text 'SD FIT slot B' 'atlantian-B.itb' scripts/populate-boot-files.sh scripts/build-atlantian-debs.sh
require_text 'SD active-slot marker' 'atlantian-slot-B' scripts/populate-boot-files.sh scripts/build-atlantian-debs.sh
require_text 'SD FIT SHA-256' 'hash-1 { algo = "sha256"; };' scripts/populate-boot-files.sh
require_text 'SD FIT boot' 'bootm 0x02000000' scripts/populate-boot-files.sh
require_text 'legacy SD kernel migration fallback' 'fatload mmc 0:1 0x02000000 uImage' scripts/populate-boot-files.sh
require_text 'legacy SD DT migration fallback' 'fatload mmc 0:1 0x01F00000 devicetree.dtb' scripts/populate-boot-files.sh
require_text 'NAND stage hook is explicit' 'atln-stage.scr' scripts/populate-boot-files.sh

# NAND U-Boot.
require_text 'NAND SPL support' '--enable SPL_NAND_SUPPORT' scripts/build-uboot-nand.sh
require_text 'NAND SPL driver support' '--enable SPL_NAND_DRIVERS' scripts/build-uboot-nand.sh
require_text 'NAND SPL MTD core' 'CONFIG_SPL_MTD=y' scripts/build-uboot-nand.sh
require_text 'NAND SPL raw core' 'CONFIG_SPL_NAND_INIT=y' scripts/build-uboot-nand.sh
require_text 'Zynq NAND driver' '--enable NAND_ZYNQ' scripts/build-uboot-nand.sh
require_text 'NAND primary U-Boot offset' 'CONFIG_SYS_NAND_U_BOOT_OFFS' scripts/build-uboot-nand.sh
require_text 'NAND redundant U-Boot offset' 'CONFIG_SYS_NAND_U_BOOT_OFFS_REDUND' scripts/build-uboot-nand.sh
require_text 'NAND immutable environment' '--enable ENV_IS_NOWHERE' scripts/build-uboot-nand.sh
require_text 'NAND no saved environment' '--disable ENV_IS_IN_NAND' scripts/build-uboot-nand.sh
require_text 'NAND watchdog remains disarmed' '--disable WATCHDOG_AUTOSTART' scripts/build-uboot-nand.sh
require_text 'read-only NAND probe patch' 'AtlANTian: keep NAND probing read-only' scripts/patch-uboot-nand.sh
require_text 'factory bad-block markers preserved' 'AtlANTian: preserve factory OOB bad-block markers' scripts/patch-uboot-nand.sh
require_text 'SPL bad-block-aware reader' 'AtlANTian Zynq SPL NAND reader' scripts/patch-uboot-nand.sh
require_text 'Zynq NAND selects SPL MTD core' 'select SPL_MTD' scripts/patch-uboot-nand.sh
require_text 'Zynq NAND selects SPL raw core' 'select SPL_NAND_INIT' scripts/patch-uboot-nand.sh
require_text 'exact NAND kernel length' 'kernel_size=$(($(stat -c %s "$ZIMAGE") + 64))' scripts/build-uboot-nand.sh
require_text 'exact NAND initramfs length' 'initrd_size=$(($(stat -c %s "$INITRAMFS") + 64))' scripts/build-uboot-nand.sh
require_text 'exact NAND DT length' 'dtb_size=$(stat -c %s "$DTB")' scripts/build-uboot-nand.sh
require_text 'NAND read-length audit sidecar' 'raw-boot-sizes.env' scripts/build-uboot-nand.sh scripts/test-nand-artifacts.sh

# NAND geometry and early root.
[[ $ATLANTIAN_NAND_TOTAL_MIB -eq 256 ]] || fail 'NAND layout: total size must remain 256 MiB'
[[ $ATLANTIAN_NAND_BOOT_MIB -eq 16 ]] || fail 'NAND layout: raw boot reserve must remain 16 MiB'
[[ $ATLANTIAN_NAND_UBI_OFFSET_BYTES -eq 16777216 ]] || fail 'NAND layout: UBI must begin at 16 MiB'
[[ $ATLANTIAN_NAND_ROOTFS_FORMAT == squashfs ]] || fail 'NAND layout: immutable lower must be SquashFS'
[[ $ATLANTIAN_NAND_ROOTFS_COMPRESSOR == zstd ]] || fail 'NAND layout: immutable lower must use Zstd'
[[ $ATLANTIAN_NAND_OVERLAY_COMPRESSOR == lzo ]] || fail 'NAND layout: writable UBIFS upper must use LZO'
[[ $ATLANTIAN_NAND_ROOTFS_BLOCK_BYTES -ge 131072 ]] || fail 'NAND layout: SquashFS block size unexpectedly small'
[[ $ATLANTIAN_NAND_MIN_OVERLAY_MIB -ge 32 ]] || fail 'NAND layout: internal overlay reserve below 32 MiB'
[[ $ATLANTIAN_NAND_CI_BAD_PEB_RESERVE -ge 16 ]] || fail 'NAND layout: CI bad-PEB reserve is too small'
for opt in CONFIG_MTD_NAND_PL35X CONFIG_MTD_NAND_ECC_SW_BCH CONFIG_MTD_UBI CONFIG_MTD_UBI_BLOCK \
  CONFIG_UBIFS_FS CONFIG_UBIFS_FS_LZO CONFIG_SQUASHFS CONFIG_SQUASHFS_XATTR CONFIG_SQUASHFS_ZSTD CONFIG_OVERLAY_FS; do
  require_text "kernel early-root $opt" "$opt=y" config/kernel.fragment
done
require_text 'Linux NAND BCH strength' 'nand-ecc-strength = <4>;' board/zynq-bitmain-antminer-s9.dts
require_text 'compressed immutable SquashFS build' 'mksquashfs "$ROOTFS" "$OUTDIR/rootfs.squashfs"' scripts/build-nand-bundle.sh
require_text 'SquashFS Zstd build' '-comp zstd' scripts/build-nand-bundle.sh
require_text 'static rootfs UBI volume' 'ubimkvol /dev/ubi0 -N rootfs -t static' scripts/atlantian-nand-install.sh
require_text 'ubiblock early root' 'ubiblock --create' scripts/atlantian-nand-init.sh scripts/atlantian-nand-install.sh
require_text 'read-only SquashFS lower' 'mount -t squashfs -o ro,nodev' scripts/atlantian-nand-init.sh scripts/atlantian-nand-install.sh
require_text 'writable NAND upper LZO/noatime' 'rw,noatime,compr=lzo' scripts/atlantian-nand-init.sh scripts/atlantian-nand-install.sh
require_text 'volatile NAND journal' 'Storage=volatile' scripts/build-nand-rootfs.sh
require_text 'volatile NAND tmp' 'tmpfs /tmp tmpfs' scripts/build-nand-rootfs.sh

# NAND installation and extroot safety.
require_text 'raw+OOB factory backup' '--noecc --oob --bb=dumpbad' scripts/atlantian-nand-backup.sh
reject_regex 'backup helper must remain read-only' 'nandwrite|flash_erase|ubiformat|mtdpart[[:space:]]+add' scripts/atlantian-nand-backup.sh
require_text 'verified automatic backup' 'Factory backup verified:' scripts/atlantian-nand-install.sh
require_text 'single destructive confirmation' 'type INSTALL' scripts/atlantian-nand-install.sh
require_text 'raw boot stage marker' 'atln-stage.done' scripts/build-nand-bundle.sh scripts/atlantian-nand-install.sh
require_text 'final raw-layout readback' 'Final full-layout read-back verification' scripts/build-nand-bundle.sh
require_text 'fresh install stages raw boot first' 'stage_raw_boot fresh' scripts/atlantian-nand-install.sh
require_text 'automatic resume mode' '--resume-auto' scripts/atlantian-nand-install.sh systemd/atlantian-nand-auto-resume.service
require_text 'resume writes UBI' 'write_ubi "$mode" "$id"' scripts/atlantian-nand-install.sh
require_text 'UBI formatting happens in Linux resume' 'ubiformat "$UBI_MTD" -y' scripts/atlantian-nand-install.sh
require_text 'physical boot-source handoff' 'Physically move the boot-source jumper from SD to NAND.' scripts/atlantian-nand-install.sh
require_text 'extroot token' '.extroot-token' scripts/atlantian-storage.sh scripts/atlantian-nand-init.sh scripts/atlantian-nand-install.sh scripts/atlantian-nand-upgrade.sh
require_text 'extroot recovery directory in storage manager' 'EXTROOT_DIR=.atlantian-extroot' scripts/atlantian-storage.sh
require_text 'extroot recovery directory in early boot' 'external_root=/run/atlantian/external-overlay/.atlantian-extroot' scripts/atlantian-nand-init.sh
require_text 'extroot external token path' 'external_token=$external_root/token' scripts/atlantian-nand-init.sh
require_text 'extroot token ownership comparison' '[ -s "$external_token" ] && [ "$(cat "$external_token")" = "$(cat "$internal_token")" ]' scripts/atlantian-nand-init.sh
require_text 'extroot defaults to internal upper' 'upper=/run/atlantian/internal-overlay/upper' scripts/atlantian-nand-init.sh
require_text 'extroot defaults to internal mode' 'mode=internal' scripts/atlantian-nand-init.sh
require_text 'extroot adoption tied to installer card' 'installer_card_id || {' scripts/atlantian-storage.sh
reject_text 'extroot adoption must not wipe recovery card' 'wipefs -a "$TARGET"' scripts/atlantian-storage.sh
require_text 'extroot requires explicit adoption' 'Type ADOPT' scripts/atlantian-storage.sh
require_text 'simple extroot command' 'atlantian-storage adopt' scripts/atlantian-login-info.sh

# Update boundaries and release-upgrade gate.
require_text 'live NAND .deb update refusal' 'atlantian-kernel cannot update a live NAND edition' scripts/build-atlantian-debs.sh
require_text 'SD inactive FIT staging' 'inactive=' scripts/build-atlantian-debs.sh
require_text 'SD FIT byte verification' 'cmp -s "$fit" "$target/.$dest.new"' scripts/build-atlantian-debs.sh
require_text 'SD FIT active marker' 'atlantian-slot-B' scripts/build-atlantian-debs.sh
require_text 'SD legacy migration detection' 'if [ ! -s "$target/atlantian-A.itb" ] || [ ! -s "$target/atlantian-B.itb" ]; then' scripts/build-atlantian-debs.sh
require_text 'NAND sysupgrade wrapper' 'atlantian-sysupgrade-nand' scripts/build-atlantian-debs.sh scripts/install-nand-tools.sh
require_text 'NAND maintenance tool' 'atlantian-nand-upgrade' scripts/install-nand-tools.sh scripts/atlantian-sysupgrade-nand.sh
require_text 'NAND cross-major fail closed' 'requires a clean NAND reinstall' scripts/atlantian-nand-upgrade.sh
require_text 'metadata-preserving overlay transfer' 'rsync -aHAX --numeric-ids' scripts/atlantian-nand-upgrade.sh scripts/atlantian-storage.sh
require_text 'post-base overlay reconciliation marker' 'reconcile-release' scripts/atlantian-nand-install.sh scripts/atlantian-nand-reconcile.sh
require_text 'NAND overlay reconciliation service' 'atlantian-nand-reconcile.service' scripts/install-nand-tools.sh systemd/atlantian-nand-reconcile.service
# Match the safety behavior, not one exact English sentence. The implementation
# may refine wording while still requiring both a missing/mismatched external
# upper check and a fail-closed refusal before replacing its lower.
require_regex 'external upper upgrade safety' 'external upper.*missing.*token-mismatched' scripts/atlantian-nand-upgrade.sh
require_text 'release upgrade test' 'test-release-upgrade.sh' scripts/test-build.sh
require_text 'upgrade test canonical metadata' "m['schema_version'] == 1" scripts/test-release-upgrade.sh
require_text 'upgrade checksum verification' 'source release image checksum mismatch' scripts/test-release-upgrade.sh
require_text 'upgrade dpkg audit' 'dpkg --audit' scripts/test-release-upgrade.sh

# Release products and provenance.
require_text 'unified release metadata' 'generate-release-metadata.sh' scripts/build-incremental.sh
require_text 'embedded NAND payload' 'embed-nand-bundle.sh' scripts/build-incremental.sh
require_text 'release checksums include image and bundle' 'sha256sum *.img *.tar.zst *.deb RELEASE-METADATA.json' scripts/build-incremental.sh
require_text 'NAND artifact test is a publication gate' 'test-nand-artifacts.sh' .github/workflows/build-release.yml
require_text 'release metadata schema starts at one' '"schema_version": 1' scripts/generate-release-metadata.sh
require_text 'NAND manifest schema starts at one' '"schema_version":1' scripts/build-nand-bundle.sh
require_text 'workflow concurrency guard' 'group: atlantian-release' .github/workflows/build-release.yml
require_text 'superseded-build publication guard' 'superseded by a newer main commit' .github/workflows/build-release.yml
require_text 'pinned provenance action' 'actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8' .github/workflows/build-release.yml
require_text 'upstream watcher local cadence' "cron: '17 6 * * *'" .github/workflows/debian-watch.yml
require_text 'upstream watcher local timezone' "timezone: 'Asia/Tomsk'" .github/workflows/debian-watch.yml
require_text 'release parameter section' '## Release' scripts/generate-release-notes.sh
require_text 'release storage metrics' '## Storage metrics' scripts/generate-release-notes.sh
require_text 'release artifact section' '## Artifacts' scripts/generate-release-notes.sh
require_text 'release changelog section' '## Changes' scripts/generate-release-notes.sh
require_text 'release batch policy' 'release_input_commits >= 5' .github/workflows/build-release.yml
require_text 'release batch counter' 'release-batch-state.sh' .github/workflows/build-release.yml
require_text 'presentation-only release notes excluded from builds' '!scripts/generate-release-notes.sh' .github/workflows/build-release.yml scripts/release-batch-state.sh

# Repository hygiene. Release/image identity is proven above by evaluating the
# actual variables; ordinary documentation may name the supported Debian arch.
reject_regex 'developer-local absolute path' '/home/[^/[:space:]]+/atlantian' scripts config .github README.md docs .gitignore

echo 'source contracts passed: release identity, Debian integration, board naming, release pins, shared SD/NAND userspace, transactional SD boot, raw-NAND safety and update boundaries'
