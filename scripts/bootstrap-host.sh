#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  debootstrap qemu-user qemu-user-binfmt binfmt-support \
  dosfstools e2fsprogs parted rsync xz-utils zstd ca-certificates \
  mtd-utils jq \
  git make bc bison flex libssl-dev libelf-dev libgnutls28-dev uuid-dev dwarves \
  gcc-arm-linux-gnueabihf device-tree-compiler u-boot-tools \
  python3 python3-dev python3-setuptools python3-pyelftools python3-yaml python3-jsonschema swig \
  curl wget file cpio
apt-get clean
