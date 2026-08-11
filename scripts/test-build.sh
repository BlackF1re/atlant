#!/usr/bin/env bash
set -euo pipefail

IMAGE=${1:?image}
SUMS=${2:?sums}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/config/release.env"
. "$ROOT/config/debian-snapshot.env"
. "$ROOT/config/image-layout.env"
export ATLANTIAN_VERSION ATLANTIAN_RELEASE_ID ATLANTIAN_DEB_VERSION DEBIAN_SNAPSHOT_TIMESTAMP
DIR=$(dirname "$IMAGE")
METADATA=$DIR/RELEASE-METADATA.json

[ -s "$IMAGE" ] && [ -s "$SUMS" ] && [ -s "$METADATA" ]
(cd "$DIR" && sha256sum -c "$(basename "$SUMS")")

python3 - "$IMAGE" "$METADATA" "$ATLANTIAN_BOOT_MIB" <<'PY'
import json
import os
import subprocess
import sys

image, metadata_path, expected_boot_mib = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(metadata_path, encoding='utf-8') as f:
    metadata = json.load(f)

ptable = json.loads(subprocess.check_output(['sfdisk', '--json', image], text=True))['partitiontable']
parts = ptable['partitions']
assert len(parts) == 2, len(parts)
sector_size = int(ptable.get('sectorsize', 512))
boot_bytes = int(parts[0]['size']) * sector_size
root_bytes = int(parts[1]['size']) * sector_size
image_bytes = os.path.getsize(image)
partitions_bytes = boot_bytes + root_bytes
storage = metadata['storage']
mib = 1024 * 1024

assert metadata['schema_version'] == 1
assert metadata['release'] == os.environ['ATLANTIAN_VERSION']
assert metadata['release_id'] == os.environ['ATLANTIAN_RELEASE_ID']
assert metadata['package_version'] == os.environ['ATLANTIAN_DEB_VERSION']
assert metadata['debian']['snapshot'] == os.environ['DEBIAN_SNAPSHOT_TIMESTAMP']
assert metadata['image'] == os.path.basename(image)
assert storage['boot_bytes'] == boot_bytes
assert storage['root_bytes'] == root_bytes
assert storage['boot_plus_root_bytes'] == partitions_bytes
assert storage['image_bytes'] == image_bytes
assert storage['layout_overhead_bytes'] == image_bytes - partitions_bytes
assert storage['boot_mib'] == expected_boot_mib == boot_bytes // mib
assert storage['root_mib'] == root_bytes // mib
assert storage['boot_plus_root_mib'] == partitions_bytes // mib
assert storage['image_mib'] == image_bytes // mib
PY

mapfile -t packages < <(find "$DIR" -maxdepth 1 -name '*.deb' -type f | sort)
[ "${#packages[@]}" -eq 3 ]
for file in "${packages[@]}"; do
  dpkg-deb --info "$file" >/dev/null
  [ "$(dpkg-deb -f "$file" Version)" = "$ATLANTIAN_DEB_VERSION" ] || {
    echo "wrong package version: $file" >&2
    exit 1
  }
  work_control=$(mktemp -d)
  dpkg-deb -e "$file" "$work_control"
  grep -q 'atlantian-major-upgrade-authorized' "$work_control/preinst"
  grep -Fq "target_version='$ATLANTIAN_VERSION'" "$work_control/preinst"
  grep -Fq "target_major='$DEBIAN_MAJOR'" "$work_control/preinst"
  rm -rf "$work_control"
done

platform=$(find "$DIR" -maxdepth 1 -name 'atlantian-platform_*.deb' -type f -print -quit)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$platform" "$work/root"
dpkg-deb -e "$platform" "$work/control"
[ "$(cat "$work/root/usr/lib/atlantian/version")" = "$ATLANTIAN_VERSION" ]
[ "$(cat "$work/root/usr/lib/atlantian/package-version")" = "$ATLANTIAN_DEB_VERSION" ]
[ "$(cat "$work/root/usr/lib/atlantian/debian-major")" = "$DEBIAN_MAJOR" ]
[ "$(cat "$work/root/usr/lib/atlantian/debian-codename")" = "$DEBIAN_CODENAME" ]
[ "$(cat "$work/root/usr/lib/atlantian/debian-snapshot")" = "$DEBIAN_SNAPSHOT_TIMESTAMP" ]
[ -s "$work/root/usr/lib/atlantian/runtime-sources.list" ]
[ -s "$work/root/usr/lib/atlantian/os-release" ]
grep -qx 'ID=debian' "$work/root/usr/lib/atlantian/os-release"
grep -qx 'NAME="Debian GNU/Linux"' "$work/root/usr/lib/atlantian/os-release"
grep -qx 'VARIANT_ID=atlantian' "$work/root/usr/lib/atlantian/os-release"
! [ -e "$work/root/etc/apt/sources.list" ]
! grep -q 'snapshot.debian.org' "$work/root/usr/lib/atlantian/runtime-sources.list"

# Production Actions proves the package set over the newest eligible release and
# exercises clean NAND upper rebasing with the built Debian rootfs.
run_upgrade_test=${ATLANTIAN_RELEASE_UPGRADE_TEST:-${GITHUB_ACTIONS:-false}}
case "$run_upgrade_test" in
  1|true) bash "$ROOT/scripts/test-release-upgrade.sh" "$DIR" ;;
  0|false|'') ;;
  *) echo "invalid ATLANTIAN_RELEASE_UPGRADE_TEST value: $run_upgrade_test" >&2; exit 64 ;;
esac

run_rebase_test=${ATLANTIAN_NAND_REBASE_TEST:-${GITHUB_ACTIONS:-false}}
case "$run_rebase_test" in
  1|true)
    [ -d "$ROOT/out/rootfs-nand" ] || { echo 'built NAND rootfs is missing for rebase integration' >&2; exit 2; }
    sudo -E bash "$ROOT/scripts/test-nand-rebase.sh" "$ROOT/out/rootfs-nand"
    ;;
  0|false|'') ;;
  *) echo "invalid ATLANTIAN_NAND_REBASE_TEST value: $run_rebase_test" >&2; exit 64 ;;
esac

echo 'release image, storage footprint, package checksums, Debian lifecycle, SD release upgrade, NAND rebase and identity passed'
