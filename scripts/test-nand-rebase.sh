#!/usr/bin/env bash
# Integration-test clean upper rebasing against the real built Debian rootfs.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOWER=${1:-$ROOT/out/rootfs-nand}
[[ $LOWER = /* ]] || LOWER=$ROOT/$LOWER
[[ $EUID -eq 0 ]] || { echo 'test-nand-rebase: run as root' >&2; exit 77; }
[[ -d $LOWER/etc && -x $LOWER/usr/bin/apt-mark ]] || { echo "invalid built rootfs: $LOWER" >&2; exit 2; }
command -v mountpoint >/dev/null
command -v rsync >/dev/null

workroot=$(mktemp -d "$ROOT/out/rebase-test.XXXXXX")
old_upper=$workroot/old-upper
old_work=$workroot/old-work
old_merged=$workroot/old-merged
snapshot=$workroot/snapshot
new_upper=$workroot/new-upper
new_work=$workroot/new-work
new_merged=$workroot/new-merged
mkdir -p "$old_upper" "$old_work" "$old_merged" "$new_upper" "$new_work" "$new_merged"

cleanup() {
  set +e
  mountpoint -q "$new_merged" && umount "$new_merged"
  mountpoint -q "$old_merged" && umount "$old_merged"
  rm -rf "$workroot"
}
trap cleanup EXIT INT TERM HUP

mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$old_upper,workdir=$old_work" "$old_merged"

# Persistent configuration/data must survive.
printf 'rebase-config\n' >"$old_merged/etc/atlantian-rebase-test"
mkdir -p "$old_merged/home/rebase-user"
printf 'user-data\n' >"$old_merged/home/rebase-user/data"

# A deletion in a persistent namespace must be replayed as a fresh whiteout.
[[ -e $old_merged/etc/debian_version ]] || { echo 'fixture lacks /etc/debian_version' >&2; exit 3; }
rm -f "$old_merged/etc/debian_version"

# Package payload namespaces must never move from the old upper to the new one.
printf 'stale-package-payload\n' >"$old_merged/usr/bin/atlantian-stale-payload"
chmod 0755 "$old_merged/usr/bin/atlantian-stale-payload"

# Exercise package intent using the real target package database via binfmt/qemu.
auto_pkg=$(chroot "$old_merged" apt-mark showauto | sed -n '1p')
[[ -n $auto_pkg ]] || { echo 'fixture has no auto package for manual-intent test' >&2; exit 3; }
chroot "$old_merged" apt-mark manual "$auto_pkg" >/dev/null
chroot "$old_merged" dpkg-query -W bash >/dev/null
chroot "$old_merged" apt-mark hold bash >/dev/null

umount "$old_merged"

sh "$ROOT/scripts/atlantian-nand-rebase.sh" capture \
  "$LOWER" "$old_upper" "$old_work" "$snapshot"

grep -Fxq "$auto_pkg" "$snapshot/manual-extra.packages"
grep -Fxq bash "$snapshot/user-holds.packages"
grep -Fxq 'etc/debian_version' "$snapshot/deleted.paths"
[[ ! -e $snapshot/delta/usr/bin/atlantian-stale-payload ]]
[[ ! -e $snapshot/delta/var/lib/dpkg/status ]]

release=$(cat "$LOWER/usr/lib/atlantian/version")
sh "$ROOT/scripts/atlantian-nand-rebase.sh" restore \
  "$snapshot" "$LOWER" "$new_upper" "$new_work" "$release"

mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$new_upper,workdir=$new_work" "$new_merged"
[[ $(cat "$new_merged/etc/atlantian-rebase-test") == rebase-config ]]
[[ $(cat "$new_merged/home/rebase-user/data") == user-data ]]
[[ ! -e $new_merged/etc/debian_version ]]
[[ ! -e $new_merged/usr/bin/atlantian-stale-payload ]]
[[ $(cat "$new_merged/var/lib/atlantian/nand/reconcile-release") == "$release" ]]
grep -Fxq "$auto_pkg" "$new_merged/var/lib/atlantian/nand/rebase-intent/manual-extra.packages"
grep -Fxq bash "$new_merged/var/lib/atlantian/nand/rebase-intent/user-holds.packages"
[[ ! -e $new_upper/var/lib/dpkg/status ]]

umount "$new_merged"
trap - EXIT INT TERM HUP
rm -rf "$workroot"
echo "clean NAND rebase integration passed (manual intent: $auto_pkg)"
