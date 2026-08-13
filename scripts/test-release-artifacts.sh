#!/usr/bin/env bash
# Validate the release payload itself. Release-upgrade and NAND-rebase integration
# gates are intentionally separate workflow stages.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${1:-$ROOT/artifacts/current}
. "$ROOT/config/release.env"
. "$ROOT/config/debian-snapshot.env"
. "$ROOT/config/atlantian-releases.conf"

IMAGE=$DIR/$ATLANTIAN_IMAGE_NAME.img
COMPRESSED_IMAGE=$IMAGE.xz
NAND_BUNDLE=$DIR/atlantian-nand-$ATLANTIAN_VERSION.tar.zst
SUMS=$DIR/SHA256SUMS
METADATA=$DIR/RELEASE-METADATA.json

fail() { printf 'release artifacts: %s\n' "$*" >&2; exit 1; }
[[ -s $IMAGE ]] || fail "missing image: $IMAGE"
[[ -s $COMPRESSED_IMAGE ]] || fail "missing compressed image: $COMPRESSED_IMAGE"
[[ -s $NAND_BUNDLE ]] || fail "missing NAND bundle: $NAND_BUNDLE"
[[ -s $SUMS ]] || fail "missing checksums: $SUMS"
[[ -s $METADATA ]] || fail "missing release metadata: $METADATA"
[[ $(find "$DIR" -maxdepth 1 -name '*.img' -type f | wc -l) -eq 1 ]] || fail 'verified artifact must contain exactly one raw .img'
[[ $(find "$DIR" -maxdepth 1 -name '*.img.xz' -type f | wc -l) -eq 1 ]] || fail 'verified artifact must contain exactly one compressed .img.xz'
[[ $(find "$DIR" -maxdepth 1 -name '*.tar.zst' -type f | wc -l) -eq 1 ]] || fail 'release must contain exactly one .tar.zst'
[[ $(find "$DIR" -maxdepth 1 -name '*.deb' -type f | wc -l) -eq 3 ]] || fail 'release must contain exactly three .deb packages'
[[ -s ${IMAGE%.img}.packages.tsv ]] || fail 'package manifest sidecar is missing'
[[ -s ${IMAGE%.img}.snapshot.txt ]] || fail 'snapshot sidecar is missing'

for required in "$(basename "$IMAGE")" "$(basename "$COMPRESSED_IMAGE")" "$(basename "$NAND_BUNDLE")" RELEASE-METADATA.json; do
  grep -Eq "^[0-9a-f]{64}[[:space:]]+${required//./\\.}$" "$SUMS" \
    || fail "SHA256SUMS is missing $required"
done
xz -t "$COMPRESSED_IMAGE" || fail 'compressed image XZ integrity check failed'
raw_sha=$(sha256sum "$IMAGE" | awk '{print $1}')
decoded_sha=$(xz -dc "$COMPRESSED_IMAGE" | sha256sum | awk '{print $1}')
[[ "$decoded_sha" = "$raw_sha" ]] || fail 'compressed image does not round-trip to the verified raw image'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
kernel_deb=$(find "$DIR" -maxdepth 1 -name 'atlantian-kernel_*.deb' -type f -print -quit)
platform_deb=$(find "$DIR" -maxdepth 1 -name 'atlantian-platform_*.deb' -type f -print -quit)
[[ -s $kernel_deb && -s $platform_deb ]] || fail 'kernel/platform packages are incomplete'
[[ $(dpkg-deb -f "$kernel_deb" Version) == "$ATLANTIAN_DEB_VERSION" ]] || fail 'kernel package version mismatch'
[[ $(dpkg-deb -f "$platform_deb" Version) == "$ATLANTIAN_DEB_VERSION" ]] || fail 'platform package version mismatch'
[[ $(dpkg-deb -f "$platform_deb" Homepage) == "https://github.com/$ATLANTIAN_GITHUB_REPO" ]] \
  || fail 'platform package Homepage does not match the active release repository'

dpkg-deb -c "$kernel_deb" >"$work/kernel.list"
! grep -qE ' ./boot/' "$work/kernel.list" || fail 'kernel package must not own live /boot paths'
for path in BOOT.bin u-boot.img boot.scr; do
  grep -q "usr/lib/atlantian/boot/$path" "$work/kernel.list" || fail "kernel package is missing $path"
done
dpkg-deb -e "$kernel_deb" "$work/kernel-control"
grep -q '/usr/lib/atlantian/boot' "$work/kernel-control/postinst" || fail 'kernel postinst does not refresh SD boot payload'

dpkg-deb -c "$platform_deb" >"$work/platform.list"
! grep -qE ' ./etc/(issue\.net|os-release|default/zramswap)$' "$work/platform.list" || fail 'platform package owns factory-only files'
for path in \
  usr/local/sbin/atlantian-nand-install \
  usr/local/sbin/atlantian-storage \
  usr/local/sbin/atlantian-nand-rebase \
  usr/local/sbin/atlantian-nand-reconcile \
  usr/lib/atlantian/version \
  usr/lib/atlantian/package-version \
  usr/lib/atlantian/debian-snapshot \
  usr/lib/atlantian/release-repo \
  usr/lib/atlantian/os-release \
  usr/lib/systemd/system/atlantian-nand-auto-resume.service \
  usr/lib/systemd/system/atlantian-nand-reconcile.service \
  etc/apt/apt.conf.d/10atlantian-volatile \
  usr/lib/systemd/system/run-apt.mount \
  usr/lib/tmpfiles.d/atlantian-apt.conf; do
  grep -q "$path" "$work/platform.list" || fail "platform package is missing $path"
done
! grep -qE 'etc/systemd/system/atlantian-.*\.(service|timer)' "$work/platform.list" || fail 'vendor systemd units leaked into /etc'

dpkg-deb -e "$platform_deb" "$work/platform-control"
if [[ -s $work/platform-control/conffiles ]]; then
  ! grep -qE '^/etc/systemd/system/atlantian-.*\.(service|timer)$' "$work/platform-control/conffiles" \
    || fail 'vendor systemd unit is registered as a conffile'
fi

dpkg-deb -x "$platform_deb" "$work/platform-root"
cmp -s "$ROOT/config/apt-volatile.conf" "$work/platform-root/etc/apt/apt.conf.d/10atlantian-volatile" \
  || fail 'packaged APT runtime policy differs from source'
cmp -s "$ROOT/systemd/run-apt.mount" "$work/platform-root/usr/lib/systemd/system/run-apt.mount" \
  || fail 'packaged APT tmpfs mount differs from source'
cmp -s "$ROOT/systemd/atlantian-apt-tmpfiles.conf" "$work/platform-root/usr/lib/tmpfiles.d/atlantian-apt.conf" \
  || fail 'packaged APT tmpfiles policy differs from source'
[[ $(cat "$work/platform-root/usr/lib/atlantian/version") == "$ATLANTIAN_VERSION" ]] || fail 'packaged semantic version mismatch'
[[ $(cat "$work/platform-root/usr/lib/atlantian/package-version") == "$ATLANTIAN_DEB_VERSION" ]] || fail 'packaged Debian version mismatch'
[[ $(cat "$work/platform-root/usr/lib/atlantian/debian-snapshot") == "$DEBIAN_SNAPSHOT_TIMESTAMP" ]] || fail 'packaged snapshot mismatch'
[[ $(cat "$work/platform-root/usr/lib/atlantian/release-repo") == "$ATLANTIAN_GITHUB_REPO" ]] || fail 'packaged release repository mismatch'
grep -qx 'ID=debian' "$work/platform-root/usr/lib/atlantian/os-release" || fail 'packaged OS ID is not Debian-compatible'
grep -qx 'VARIANT_ID=atlantian' "$work/platform-root/usr/lib/atlantian/os-release" || fail 'packaged AtlANTian variant identity is missing'
grep -qx "ATLANTIAN_RELEASE_REPOSITORY=\"$ATLANTIAN_GITHUB_REPO\"" "$work/platform-root/usr/lib/atlantian/os-release" \
  || fail 'packaged os-release repository identity mismatch'

ATLANTIAN_RELEASE_UPGRADE_TEST=false ATLANTIAN_NAND_REBASE_TEST=false \
  bash "$ROOT/scripts/test-build.sh" "$IMAGE" "$SUMS"

python3 - "$METADATA" "${IMAGE%.img}.packages.tsv" "$ATLANTIAN_IMAGE_NAME.img" "$ATLANTIAN_VERSION" "$ATLANTIAN_DEB_VERSION" "$DEBIAN_SNAPSHOT_TIMESTAMP" <<'PY'
import json
import sys

path, package_manifest, expected_image, release, package_version, snapshot = sys.argv[1:]
with open(path, encoding='utf-8') as stream:
    metadata = json.load(stream)
with open(package_manifest, encoding='utf-8') as stream:
    package_count = sum(1 for line in stream if line.strip())

assert metadata['schema_version'] == 1
assert metadata['release'] == release
assert metadata['package_version'] == package_version
assert metadata['debian']['snapshot'] == snapshot
assert metadata['debian']['package_count'] == package_count > 0
assert metadata['platform']['board'] == 'Bitmain Antminer S9'
assert 'architecture' not in metadata['platform']
assert set(metadata['products']) == {'sd', 'nand'}
assert metadata['products']['sd']['image'] == expected_image
assert set(metadata['products']['nand']) == {'install_source_image', 'installed'}
assert metadata['products']['nand']['install_source_image'] == expected_image

storage = metadata['storage']
assert storage['image_bytes'] > storage['boot_plus_root_bytes'] > 0
for name in ('boot', 'root'):
    fs = storage['filesystems'][name]
    assert fs['filesystem'] in {'vfat', 'ext4'}
    assert fs['partition_bytes'] > 0
    assert 0 < fs['total_bytes'] <= fs['partition_bytes']
    assert 0 <= fs['used_bytes'] <= fs['total_bytes']
    assert 0 <= fs['available_bytes'] <= fs['total_bytes']
    assert 0 <= fs['reserved_bytes'] <= fs['total_bytes']
    assert 0.0 <= fs['used_percent'] <= 100.0

nand = metadata['products']['nand']['installed']
assert nand['schema_version'] == 1
assert nand['compression']['rootfs_squashfs'] == 'zstd'
assert nand['compression']['overlay_ubifs'] == 'lzo'
assert nand['volumes']['rootfs']['type'] == 'static'
assert nand['volumes']['rootfs']['filesystem'] == 'squashfs'
assert nand['volumes']['rootfs']['image_bytes'] <= nand['volumes']['rootfs']['bytes']
assert nand['volumes']['overlay']['type'] == 'dynamic'
assert nand['volumes']['overlay']['filesystem'] == 'ubifs'
assert nand['volumes']['overlay']['minimum_bytes'] == nand['volumes']['overlay']['minimum_lebs'] * nand['nand']['leb_bytes']
assert nand['volumes']['overlay']['minimum_bytes'] > 0
PY

echo 'release inventory, raw/XZ image equivalence, semantic/package/repository identity, measured storage metadata and volatile APT payload passed'
