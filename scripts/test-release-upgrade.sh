#!/usr/bin/env bash
# Release-upgrade gate: install the newly built AtlANTian packages into the
# newest eligible published SD release and verify that persistent state survives.
set -euo pipefail

ARTIFACT_DIR=${1:?artifact directory}
PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$PROJECT/config/release.env"
TARGET_VERSION=${ATLANTIAN_VERSION:?}
TARGET_PACKAGE_VERSION=${ATLANTIAN_DEB_VERSION:?}
TARGET_MAJOR=${DEBIAN_MAJOR:?}
REPO=${ATLANTIAN_RELEASE_UPGRADE_REPO:-${GITHUB_REPOSITORY:-BlackF1re/atlantian}}
API=${ATLANTIAN_RELEASE_UPGRADE_API:-https://api.github.com}
EXPAND_MIB=${ATLANTIAN_RELEASE_UPGRADE_EXPAND_MIB:-2048}

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

fail() { printf 'release upgrade: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"; }
for cmd in curl python3 jq dpkg dpkg-deb sha256sum losetup mount umount mountpoint parted e2fsck resize2fs chroot cmp awk truncate update-binfmts; do
  need "$cmd"
done
[[ $TARGET_MAJOR =~ ^[0-9]+$ ]] || fail 'target Debian major is not numeric'
[[ $EXPAND_MIB =~ ^[0-9]+$ ]] && (( EXPAND_MIB >= 1024 )) || fail 'ATLANTIAN_RELEASE_UPGRADE_EXPAND_MIB must be at least 1024'

canonical_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]
}
ordering_version() {
  local value=$1 core prerelease
  if [[ $value =~ ^([0-9]+\.[0-9]+\.[0-9]+)-(.+)$ ]]; then
    core=${BASH_REMATCH[1]}
    prerelease=${BASH_REMATCH[2]}
    printf '%s~%s\n' "$core" "$prerelease"
  else
    printf '%s\n' "$value"
  fi
}
version_lt() { dpkg --compare-versions "$(ordering_version "$1")" lt "$(ordering_version "$2")"; }

platform=$(find "$ARTIFACT_DIR" -maxdepth 1 -name 'atlantian-platform_*.deb' -type f -print -quit)
kernel=$(find "$ARTIFACT_DIR" -maxdepth 1 -name 'atlantian-kernel_*.deb' -type f -print -quit)
release=$(find "$ARTIFACT_DIR" -maxdepth 1 -name 'atlantian-release_*.deb' -type f -print -quit)
[[ -s $platform && -s $kernel && -s $release ]] || fail 'target package set is incomplete'
for pkg in "$platform" "$kernel" "$release"; do
  [[ $(dpkg-deb -f "$pkg" Version) == "$TARGET_PACKAGE_VERSION" ]] || fail "wrong target package version: $pkg"
done

WORK=$(mktemp -d)
ROOTFS=$WORK/rootfs
LOOP=
cleanup() {
  set +e
  for path in "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/boot" "$ROOTFS"; do
    mountpoint -q "$path" && umount -l "$path"
  done
  [[ -n ${LOOP:-} ]] && losetup -d "$LOOP" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$ROOTFS" "$WORK/download"

api_headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
if [[ -n ${GH_TOKEN:-${GITHUB_TOKEN:-}} ]]; then
  api_headers+=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}")
fi
curl -fsSL --retry 3 --connect-timeout 20 "${api_headers[@]}" \
  "$API/repos/$REPO/releases?per_page=100" -o "$WORK/releases.json"

SOURCE_TAG=
SOURCE_VERSION=
while IFS= read -r tag; do
  [[ $tag == v* ]] || continue
  version=${tag#v}
  canonical_version "$version" || continue
  version_lt "$version" "$TARGET_VERSION" || continue
  release_json=$(jq -c --arg tag "$tag" '.[] | select(.draft == false and .tag_name == $tag)' "$WORK/releases.json" | head -n1)
  [[ -n $release_json ]] || continue
  image_name="atlantian-$version.img"
  for required in "$image_name" RELEASE-METADATA.json SHA256SUMS; do
    printf '%s' "$release_json" | jq -e --arg name "$required" '.assets[] | select(.name == $name)' >/dev/null || { release_json=; break; }
  done
  [[ -n $release_json ]] || continue
  if [[ -z $SOURCE_VERSION ]] || version_lt "$SOURCE_VERSION" "$version"; then
    SOURCE_TAG=$tag
    SOURCE_VERSION=$version
  fi
done < <(jq -r '.[] | select(.draft == false) | .tag_name // empty' "$WORK/releases.json")

if [[ -z $SOURCE_TAG ]]; then
  echo 'No eligible published source release exists; release-upgrade gate is not applicable yet.'
  exit 0
fi

mapfile -t asset_info < <(python3 - "$WORK/releases.json" "$SOURCE_TAG" "$SOURCE_VERSION" <<'PY'
import json, sys
path, wanted, version = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    releases = json.load(f)
release = next((r for r in releases if not r.get('draft') and r.get('tag_name') == wanted), None)
if release is None:
    raise SystemExit('selected source release disappeared from API response')
assets = {a.get('name'): a.get('browser_download_url') for a in release.get('assets', [])}
for name in (f'atlantian-{version}.img', 'RELEASE-METADATA.json', 'SHA256SUMS'):
    url = assets.get(name)
    if not url:
        raise SystemExit(f'source release is missing canonical asset: {name}')
    print(name + '\t' + url)
PY
)
[[ ${#asset_info[@]} -eq 3 ]] || fail "cannot resolve assets for $SOURCE_TAG"
IFS=$'\t' read -r image_name image_url <<<"${asset_info[0]}"
IFS=$'\t' read -r metadata_name metadata_url <<<"${asset_info[1]}"
IFS=$'\t' read -r sums_name sums_url <<<"${asset_info[2]}"

IMAGE=$WORK/download/$image_name
METADATA=$WORK/download/$metadata_name
SUMS=$WORK/download/$sums_name
echo "SD release upgrade gate: $SOURCE_TAG -> v$TARGET_VERSION"
curl -fL --retry 3 --connect-timeout 20 -o "$IMAGE" "$image_url"
curl -fL --retry 3 --connect-timeout 20 -o "$METADATA" "$metadata_url"
curl -fL --retry 3 --connect-timeout 20 -o "$SUMS" "$sums_url"
python3 - "$METADATA" "$SOURCE_VERSION" "$image_name" <<'PY'
import json, sys
path, version, image = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    m = json.load(f)
assert m['schema_version'] == 1
assert m['release'] == version
assert m['image'] == image
PY
expected=$(awk -v name="$image_name" '$2 == name || $2 == "*" name { print $1; exit }' "$SUMS")
[[ $expected =~ ^[0-9a-f]{64}$ ]] || fail "SHA256SUMS has no digest for $image_name"
actual=$(sha256sum "$IMAGE" | awk '{print $1}')
[[ $actual == "$expected" ]] || fail "source release image checksum mismatch: expected $expected, got $actual"

truncate -s "+${EXPAND_MIB}M" "$IMAGE"
parted -s "$IMAGE" resizepart 2 100%
LOOP=$(losetup --find --show --partscan "$IMAGE")
udevadm settle 2>/dev/null || true
[[ -b ${LOOP}p1 && -b ${LOOP}p2 ]] || fail "partition devices were not created for $LOOP"
set +e
e2fsck -fy "${LOOP}p2" >/dev/null
e2fsck_rc=$?
set -e
(( e2fsck_rc <= 1 )) || fail "e2fsck failed for source release rootfs (exit $e2fsck_rc)"
resize2fs "${LOOP}p2" >/dev/null
mount "${LOOP}p2" "$ROOTFS"
mkdir -p "$ROOTFS/boot"
mount "${LOOP}p1" "$ROOTFS/boot"

SOURCE_INSTALLED=$(cat "$ROOTFS/usr/lib/atlantian/version" 2>/dev/null || true)
[[ $SOURCE_INSTALLED == "$SOURCE_VERSION" ]] || fail "release/image version mismatch: tag $SOURCE_VERSION, image $SOURCE_INSTALLED"
SOURCE_MAJOR=${SOURCE_INSTALLED%%.*}
[[ $SOURCE_MAJOR =~ ^[0-9]+$ ]] || fail 'source image has invalid Debian-major marker'

printf 'upgrade-persistence-sentinel\n' >"$ROOTFS/etc/atlantian-upgrade-test.conf"
printf '0123456789abcdef0123456789abcdef\n' >"$ROOTFS/etc/machine-id"
mkdir -p "$ROOTFS/etc/ssh"
printf 'upgrade-host-key-sentinel\n' >"$ROOTFS/etc/ssh/ssh_host_ed25519_key"
chmod 0600 "$ROOTFS/etc/ssh/ssh_host_ed25519_key"
cp "$ROOTFS/etc/machine-id" "$WORK/machine-id.before"
cp "$ROOTFS/etc/ssh/ssh_host_ed25519_key" "$WORK/host-key.before"
cp "$ROOTFS/etc/atlantian-upgrade-test.conf" "$WORK/persistent.before"
cp "$ROOTFS/boot/BOOT.bin" "$WORK/BOOT.bin.before"

if [[ -x /usr/bin/qemu-arm-static ]]; then
  install -m 0755 /usr/bin/qemu-arm-static "$ROOTFS/usr/bin/qemu-arm-static"
fi
for fs in dev proc sys; do mkdir -p "$ROOTFS/$fs"; done
mount --bind /dev "$ROOTFS/dev"
mkdir -p "$ROOTFS/dev/pts"
mount -t devpts devpts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mkdir -p "$ROOTFS/tmp"
for pkg in "$platform" "$kernel" "$release"; do cp "$pkg" "$ROOTFS/tmp/$(basename "$pkg")"; done

if (( TARGET_MAJOR == SOURCE_MAJOR )); then
  chroot "$ROOTFS" /bin/bash -euxc '
    export DEBIAN_FRONTEND=noninteractive
    dpkg -i /tmp/atlantian-platform_*.deb /tmp/atlantian-kernel_*.deb /tmp/atlantian-release_*.deb || apt-get -f install -y
    dpkg --audit
  '
elif (( TARGET_MAJOR == SOURCE_MAJOR + 1 )); then
  install -d -m 0755 "$ROOTFS/run"
  printf '%s\n' "$TARGET_VERSION" >"$ROOTFS/run/atlantian-major-upgrade-authorized"
  chroot "$ROOTFS" /bin/bash -euxc '
    export DEBIAN_FRONTEND=noninteractive
    dpkg -i /tmp/atlantian-platform_*.deb /tmp/atlantian-kernel_*.deb /tmp/atlantian-release_*.deb || apt-get -f install -y
    apt-get update
    apt-get full-upgrade -y
    dpkg --audit
  '
  rm -f "$ROOTFS/run/atlantian-major-upgrade-authorized"
else
  fail "source release Debian major $SOURCE_MAJOR is not a supported predecessor of target $TARGET_MAJOR"
fi

[[ $(cat "$ROOTFS/usr/lib/atlantian/version") == "$TARGET_VERSION" ]] || fail 'target release identity was not installed'
[[ $(cat "$ROOTFS/usr/lib/atlantian/package-version") == "$TARGET_PACKAGE_VERSION" ]] || fail 'target package identity was not installed'
grep -qx 'ID=debian' "$ROOTFS/etc/os-release" || fail 'upgraded system no longer identifies as Debian'
grep -qx 'VARIANT_ID=atlantian' "$ROOTFS/etc/os-release" || fail 'upgraded system lost AtlANTian variant identity'
cmp -s "$WORK/machine-id.before" "$ROOTFS/etc/machine-id" || fail 'machine-id changed during package upgrade'
cmp -s "$WORK/host-key.before" "$ROOTFS/etc/ssh/ssh_host_ed25519_key" || fail 'SSH host key changed during package upgrade'
cmp -s "$WORK/persistent.before" "$ROOTFS/etc/atlantian-upgrade-test.conf" || fail 'persistent /etc state changed during package upgrade'
[[ -s "$ROOTFS/boot/BOOT.bin" && -s "$ROOTFS/boot/u-boot.img" && -s "$ROOTFS/boot/boot.scr" ]] || fail 'SD boot assets are missing after package upgrade'

new_conffiles=$(chroot "$ROOTFS" dpkg-query -W -f='${Conffiles}\n' atlantian-platform)
if grep -qE '^ /etc/systemd/system/atlantian-.*\.(service|timer)( |$)' <<<"$new_conffiles"; then
  fail 'atlantian-platform registers vendor systemd units as conffiles'
fi

echo "SD release upgrade gate passed: $SOURCE_TAG -> v$TARGET_VERSION"
