#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { echo "runtime policy contract: $*" >&2; exit 1; }
require() {
  local needle=$1 file=$2
  grep -Fq -- "$needle" "$file" || fail "$file is missing: $needle"
}
reject() {
  local needle=$1 file=$2
  ! grep -Fq -- "$needle" "$file" || fail "$file must not contain: $needle"
}

APT_CONF=config/apt-volatile.conf
MOUNT=systemd/run-apt.mount
TMPFILES=systemd/atlantian-apt-tmpfiles.conf
INSTALLER=scripts/install-runtime-policy.sh

require 'Dir::State::Lists "/run/apt/lists/";' "$APT_CONF"
require 'APT::Keep-Downloaded-Packages "false";' "$APT_CONF"
reject 'Dir::Cache::archives "/run/apt/archives/";' "$APT_CONF"
require 'Dir::Cache::pkgcache "";' "$APT_CONF"
require 'Dir::Cache::srcpkgcache "";' "$APT_CONF"
require 'Acquire::Languages "none";' "$APT_CONF"
require 'Acquire::GzipIndexes "true";' "$APT_CONF"
require 'Acquire::CompressionTypes::Order { "gz"; };' "$APT_CONF"
require 'Contents-deb::DefaultEnabled "false";' "$APT_CONF"

require 'Where=/run/apt' "$MOUNT"
require 'Type=tmpfs' "$MOUNT"
require 'nosuid,nodev,noexec,noatime' "$MOUNT"
require 'size=96M' "$MOUNT"
reject 'size=50%' "$MOUNT"
require 'WantedBy=local-fs.target' "$MOUNT"

require 'd /run/apt/lists/partial 0700 _apt root -' "$TMPFILES"
reject '/run/apt/archives' "$TMPFILES"
require '10atlantian-volatile' "$INSTALLER"
require 'local-fs.target.wants/run-apt.mount' "$INSTALLER"

require 'install-runtime-policy.sh" "$ROOT/out/rootfs"' scripts/build-incremental.sh
require 'install-runtime-policy.sh" "$ROOT/out/rootfs-nand"' scripts/build-incremental.sh
require 'etc/apt/apt.conf.d/10atlantian-volatile' scripts/build-atlantian-debs.sh
require 'usr/lib/systemd/system/run-apt.mount' scripts/build-atlantian-debs.sh
require 'usr/lib/tmpfiles.d/atlantian-apt.conf' scripts/build-atlantian-debs.sh
require 'systemctl enable --now run-apt.mount' scripts/build-atlantian-debs.sh
require 'systemd-tmpfiles --create /usr/lib/tmpfiles.d/atlantian-apt.conf' scripts/build-atlantian-debs.sh

echo 'bounded volatile APT index policy and storage-backed package transaction contracts passed'
