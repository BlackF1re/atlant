#!/usr/bin/env bash
# Validate every immutable input used to assemble a published AtlANTian release.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT"
. config/release.env
. config/debian-snapshot.env
. config/u-boot.env
ARCH=armhf

fail() { printf 'release-input validation: %s\n' "$*" >&2; exit 1; }
read_sha256_pin() {
  local file=$1 value
  [[ -s $file ]] || fail "$file is missing or empty"
  value=$(cat "$file")
  [[ $value =~ ^[0-9a-f]{64}$ ]] || fail "$file must contain exactly one lowercase SHA-256 value"
  printf '%s' "$value"
}
field() { awk -F': ' -v key="$2" '$1 == key { print $2; exit }' "$1"; }
has_arch() {
  local arches
  arches=$(field "$1" Architectures)
  [[ " $arches " == *" $ARCH "* ]]
}
verify_release_file() {
  local label=$1 url=$2 pin_file=$3 destination=$4 expected actual
  expected=$(read_sha256_pin "$pin_file")
  curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$destination" || fail "cannot download $label Release file from $url"
  actual=$(sha256sum "$destination" | awk '{print $1}')
  [[ $actual == "$expected" ]] || fail "$label Release SHA-256 mismatch: expected $expected, got $actual"
  has_arch "$destination" || fail "$label does not publish architecture $ARCH"
  printf 'validated %-22s %s\n' "$label" "$expected"
}
verify_arch_index() {
  local label=$1 url=$2
  curl -fsSL --retry 3 --connect-timeout 20 "$url" -o /dev/null || fail "$label has no binary-$ARCH archive at $url"
  printf 'validated %-22s binary-%s\n' "$label" "$ARCH"
}

[[ $DEBIAN_CODENAME =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail 'DEBIAN_CODENAME is invalid'
[[ $DEBIAN_MAJOR =~ ^[0-9]+$ ]] || fail 'DEBIAN_MAJOR must be numeric'
[[ $ARCH == armhf ]] || fail 'Debian target architecture must be armhf'

# Linux is automatically refreshed only inside one deliberately selected LTS
# series. The watcher discovers tags, but releases build an immutable commit.
[[ $ATLANTIAN_KERNEL_SERIES =~ ^[0-9]+\.[0-9]+$ ]] || fail 'ATLANTIAN_KERNEL_SERIES must be major.minor'
[[ $ATLANTIAN_KERNEL_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'ATLANTIAN_KERNEL_VERSION must be a stable patch release'
[[ $ATLANTIAN_KERNEL_VERSION == "$ATLANTIAN_KERNEL_SERIES".* ]] || fail 'kernel version is outside ATLANTIAN_KERNEL_SERIES'
[[ $ATLANTIAN_KERNEL_REPOSITORY == https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git ]] || fail 'unexpected Linux stable repository'
[[ $ATLANTIAN_KERNEL_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'ATLANTIAN_KERNEL_COMMIT must be an immutable 40-character commit ID'
printf 'validated %-22s %s (%s)\n' 'Linux source' "$ATLANTIAN_KERNEL_COMMIT" "$ATLANTIAN_KERNEL_VERSION"

[[ $ATLANTIAN_UBOOT_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'ATLANTIAN_UBOOT_COMMIT must be an immutable 40-character commit ID'
[[ $ATLANTIAN_UBOOT_VERSION =~ ^[0-9]{4}\.[0-9]{2}(\.[0-9]+)?$ ]] || fail 'ATLANTIAN_UBOOT_VERSION must be a stable YYYY.MM[.N] release'
[[ $ATLANTIAN_UBOOT_REPOSITORY == https://github.com/u-boot/u-boot.git ]] || fail 'unexpected U-Boot source repository'
[[ $ATLANTIAN_UBOOT_DEFCONFIG == bitmain_antminer_s9_defconfig ]] || fail 'unexpected U-Boot board defconfig'
printf 'validated %-22s %s (%s)\n' 'U-Boot source' "$ATLANTIAN_UBOOT_COMMIT" "$ATLANTIAN_UBOOT_VERSION"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
verify_release_file "$DEBIAN_CODENAME" "$DEBIAN_SNAPSHOT_MIRROR/dists/$DEBIAN_CODENAME/Release" debian-release.sha256 "$tmpdir/debian-release"
verify_release_file "$DEBIAN_CODENAME-updates" "$DEBIAN_SNAPSHOT_MIRROR/dists/${DEBIAN_CODENAME}-updates/Release" debian-updates-release.sha256 "$tmpdir/debian-updates-release"
verify_release_file "$DEBIAN_CODENAME-security" "$DEBIAN_SECURITY_SNAPSHOT_MIRROR/dists/${DEBIAN_CODENAME}-security/Release" debian-security-release.sha256 "$tmpdir/debian-security-release"

main_codename=$(field "$tmpdir/debian-release" Codename)
main_version=$(field "$tmpdir/debian-release" Version)
main_major=${main_version%%.*}
[[ $main_codename == "$DEBIAN_CODENAME" ]] || fail "snapshot codename is $main_codename, expected $DEBIAN_CODENAME"
[[ $main_major == "$DEBIAN_MAJOR" ]] || fail "snapshot Debian major is $main_major, expected $DEBIAN_MAJOR"
[[ $(field "$tmpdir/debian-updates-release" Codename) == "${DEBIAN_CODENAME}-updates" ]] || fail 'updates Release codename does not match the configured Debian base'
[[ $(field "$tmpdir/debian-security-release" Codename) == "${DEBIAN_CODENAME}-security" ]] || fail 'security Release codename does not match the configured Debian base'

verify_arch_index "$DEBIAN_CODENAME" "$DEBIAN_SNAPSHOT_MIRROR/dists/$DEBIAN_CODENAME/main/binary-$ARCH/Release"
verify_arch_index "$DEBIAN_CODENAME-updates" "$DEBIAN_SNAPSHOT_MIRROR/dists/${DEBIAN_CODENAME}-updates/main/binary-$ARCH/Release"
verify_arch_index "$DEBIAN_CODENAME-security" "$DEBIAN_SECURITY_SNAPSHOT_MIRROR/dists/${DEBIAN_CODENAME}-security/main/binary-$ARCH/Release"

echo "release inputs validated for Debian $DEBIAN_MAJOR ($DEBIAN_CODENAME) / $ARCH; Linux $ATLANTIAN_KERNEL_VERSION and U-Boot $ATLANTIAN_UBOOT_VERSION are immutable pins"
