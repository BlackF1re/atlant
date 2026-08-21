#!/usr/bin/env bash
# Materialize the exact immutable Linux source configured for this release.
# Cached in-tree build objects are preserved when the pin is unchanged; tracked
# AtlANTian source transforms are always reset before a new build.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$PROJECT/config/release.env"
SRC=${1:-$PROJECT/out/linux-src}
REPOSITORY=${ATLANTIAN_KERNEL_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git}

mkdir -p "$(dirname "$SRC")"
if [[ ! -d $SRC/.git ]]; then
  rm -rf "$SRC"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$REPOSITORY"
else
  git -c safe.directory="$SRC" -C "$SRC" remote set-url origin "$REPOSITORY"
fi

gitc=(git -c safe.directory="$SRC" -C "$SRC")
current=$("${gitc[@]}" rev-parse HEAD 2>/dev/null || true)
if [[ $current == "$ATLANTIAN_KERNEL_COMMIT" ]]; then
  "${gitc[@]}" reset --quiet --hard "$ATLANTIAN_KERNEL_COMMIT"
  echo "Using cached pinned Linux build tree at $ATLANTIAN_KERNEL_COMMIT"
else
  "${gitc[@]}" fetch --quiet --depth 1 origin "$ATLANTIAN_KERNEL_COMMIT"
  "${gitc[@]}" checkout --quiet --detach --force FETCH_HEAD
  # A different source revision invalidates every in-tree object. Remove all
  # ignored/untracked files only on pin transitions so the normal cache remains
  # useful between builds of the same kernel.
  "${gitc[@]}" clean -ffdqx
fi

actual=$("${gitc[@]}" rev-parse HEAD)
[[ $actual == "$ATLANTIAN_KERNEL_COMMIT" ]] || {
  echo "Linux source pin mismatch: expected $ATLANTIAN_KERNEL_COMMIT, got $actual" >&2
  exit 1
}

source_version=$(make -s -C "$SRC" kernelversion)
[[ $source_version == "$ATLANTIAN_KERNEL_VERSION" ]] || {
  echo "Linux source version mismatch: configured $ATLANTIAN_KERNEL_VERSION, source reports $source_version" >&2
  exit 1
}

printf 'Prepared Linux %s at %s\n' "$source_version" "$actual"
