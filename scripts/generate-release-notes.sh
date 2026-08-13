#!/usr/bin/env bash
set -euo pipefail

TAG=${1:-${GITHUB_REF_NAME:-}}
REF=${2:-HEAD}
[[ -n "$TAG" ]] || { echo 'release tag required' >&2; exit 64; }
CURRENT=${TAG#v}
PREVIOUS=$(git describe --tags --abbrev=0 "$REF^" 2>/dev/null || true)
METADATA=${RELEASE_METADATA:-artifacts/current/RELEASE-METADATA.json}
[[ -s $METADATA ]] || { echo "release metadata is missing: $METADATA" >&2; exit 2; }
ARTIFACT_DIR=$(dirname "$METADATA")
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$ROOT/scripts/prepare-public-release.sh" "$ARTIFACT_DIR"
COMMIT=$(git rev-parse "$REF")
SHORT_COMMIT=$(git rev-parse --short=12 "$REF")

mapfile -t values < <(python3 - "$METADATA" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    m = json.load(stream)
s = m['storage']
b = s['filesystems']['boot']
r = s['filesystems']['root']
n = m['products']['nand']['installed']
for value in (
    m['release'], m['package_version'], m['source_revision'],
    m['debian']['major'], m['debian']['codename'], m['debian']['snapshot'], m['debian']['package_count'],
    m['kernel']['version'], m['u_boot']['version'],
    s['image_bytes'],
    b['partition_bytes'], b['total_bytes'], b['used_bytes'], b['available_bytes'], b['used_percent'],
    r['partition_bytes'], r['total_bytes'], r['used_bytes'], r['available_bytes'], r['used_percent'],
    n['volumes']['rootfs']['image_bytes'], n['volumes']['rootfs']['bytes'], n['deployed_base_bytes'],
    n['volumes']['overlay']['minimum_bytes'],
):
    print(value)
PY
)

RELEASE=${values[0]}
PACKAGE_VERSION=${values[1]}
SOURCE_REVISION=${values[2]}
DEBIAN_MAJOR=${values[3]}
DEBIAN_CODENAME=${values[4]}
DEBIAN_SNAPSHOT=${values[5]}
DEBIAN_PACKAGES=${values[6]}
KERNEL=${values[7]}
UBOOT=${values[8]}
IMAGE_BYTES=${values[9]}
BOOT_PART_BYTES=${values[10]}
BOOT_FS_BYTES=${values[11]}
BOOT_USED_BYTES=${values[12]}
BOOT_AVAILABLE_BYTES=${values[13]}
BOOT_USED_PERCENT=${values[14]}
ROOT_PART_BYTES=${values[15]}
ROOT_FS_BYTES=${values[16]}
ROOT_USED_BYTES=${values[17]}
ROOT_AVAILABLE_BYTES=${values[18]}
ROOT_USED_PERCENT=${values[19]}
NAND_ROOT_IMAGE_BYTES=${values[20]}
NAND_ROOT_VOLUME_BYTES=${values[21]}
NAND_DEPLOYED_BASE_BYTES=${values[22]}
NAND_MIN_OVERLAY_BYTES=${values[23]}

[[ "$CURRENT" = "$RELEASE" ]] || {
  echo "release tag/version mismatch: tag=$CURRENT metadata=$RELEASE" >&2
  exit 2
}
[[ "$SHORT_COMMIT" = "$SOURCE_REVISION" ]] || {
  echo "release source mismatch: ref=$SHORT_COMMIT metadata=$SOURCE_REVISION" >&2
  exit 2
}

case "$RELEASE" in
  *-*) RELEASE_TYPE="prerelease (${RELEASE#*-})" ;;
  *) RELEASE_TYPE=stable ;;
esac

fmt_bytes() {
  numfmt --to=iec-i --suffix=B --format='%.2f' "$1"
}
artifact_row() {
  local path=$1 name
  [[ -s $path ]] || { echo "release artifact is missing: $path" >&2; exit 2; }
  name=$(basename "$path")
  printf '| `%s` | %s |\n' "$name" "$(fmt_bytes "$(stat -c %s "$path")")"
}
find_one() {
  local pattern=$1 label=$2
  mapfile -t matches < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name "$pattern" -print)
  (( ${#matches[@]} == 1 )) || { echo "expected one $label artifact, found ${#matches[@]}" >&2; exit 2; }
  printf '%s\n' "${matches[0]}"
}

RAW_IMAGE_NAME=$(python3 - "$METADATA" <<'PY'
import json,sys
with open(sys.argv[1], encoding='utf-8') as f: print(json.load(f)['image'])
PY
)
IMAGE="$ARTIFACT_DIR/${RAW_IMAGE_NAME}.xz"
NAND_BUNDLE="$ARTIFACT_DIR/atlantian-nand-$RELEASE.tar.zst"
PLATFORM_DEB=$(find_one 'atlantian-platform_*.deb' platform)
KERNEL_DEB=$(find_one 'atlantian-kernel_*.deb' kernel)
RELEASE_DEB=$(find_one 'atlantian-release_*.deb' release)
UPDATE_MARKER="$ARTIFACT_DIR/atlantian-update.json"
SUMS="$ARTIFACT_DIR/SHA256SUMS"

{
  printf '## Release\n\n'
  printf '| Parameter | Value |\n|---|---|\n'
  printf '| AtlANTian | `%s` |\n' "$RELEASE"
  printf '| Type | `%s` |\n' "$RELEASE_TYPE"
  printf '| Debian package version | `%s` |\n' "$PACKAGE_VERSION"
  printf '| Debian | `%s` (`%s`) |\n' "$DEBIAN_MAJOR" "$DEBIAN_CODENAME"
  printf '| Debian snapshot | `%s` |\n' "$DEBIAN_SNAPSHOT"
  printf '| Installed Debian packages | **%s** |\n' "$DEBIAN_PACKAGES"
  printf '| Linux | `%s` |\n' "$KERNEL"
  printf '| U-Boot | `%s` |\n' "$UBOOT"
  if [[ -n ${GITHUB_REPOSITORY:-} ]]; then
    printf '| Source revision | [`%s`](https://github.com/%s/commit/%s) |\n' "$SHORT_COMMIT" "$GITHUB_REPOSITORY" "$COMMIT"
  else
    printf '| Source revision | `%s` |\n' "$COMMIT"
  fi

  printf '\n## Storage metrics\n\n'
  printf '| Product / filesystem | Provisioned | Used / payload | Available | Usage |\n|---|---:|---:|---:|---:|\n'
  printf '| SD image | **%s** | — | — | — |\n' "$(fmt_bytes "$IMAGE_BYTES")"
  printf '| SD BOOT | %s partition / %s filesystem | %s | **%s** | %s%% |\n' \
    "$(fmt_bytes "$BOOT_PART_BYTES")" "$(fmt_bytes "$BOOT_FS_BYTES")" \
    "$(fmt_bytes "$BOOT_USED_BYTES")" "$(fmt_bytes "$BOOT_AVAILABLE_BYTES")" "$BOOT_USED_PERCENT"
  printf '| SD ROOT (factory image) | %s partition / %s filesystem | %s | **%s** | %s%% |\n' \
    "$(fmt_bytes "$ROOT_PART_BYTES")" "$(fmt_bytes "$ROOT_FS_BYTES")" \
    "$(fmt_bytes "$ROOT_USED_BYTES")" "$(fmt_bytes "$ROOT_AVAILABLE_BYTES")" "$ROOT_USED_PERCENT"
  printf '| NAND SquashFS root | %s UBI reservation | **%s** | — | — |\n' \
    "$(fmt_bytes "$NAND_ROOT_VOLUME_BYTES")" "$(fmt_bytes "$NAND_ROOT_IMAGE_BYTES")"
  printf '| NAND immutable deployed base | **%s** | %s | — | — |\n' \
    "$(fmt_bytes "$NAND_DEPLOYED_BASE_BYTES")" "$(fmt_bytes "$NAND_DEPLOYED_BASE_BYTES")"
  printf '| NAND writable overlay | — | — | **>= %s** guaranteed | — |\n' \
    "$(fmt_bytes "$NAND_MIN_OVERLAY_BYTES")"

  printf '\n## Artifacts\n\n'
  printf '| Artifact | Size |\n|---|---:|\n'
  artifact_row "$IMAGE"
  artifact_row "$NAND_BUNDLE"
  artifact_row "$PLATFORM_DEB"
  artifact_row "$KERNEL_DEB"
  artifact_row "$RELEASE_DEB"
  artifact_row "$UPDATE_MARKER"
  artifact_row "$METADATA"
  artifact_row "$SUMS"

  printf '\n## Changes\n\n'
  if [[ -n "$PREVIOUS" ]]; then
    git log --no-merges --format='- %s (%h)' "$PREVIOUS..$REF"
  else
    printf '%s\n' '- Initial AtlANTian release.'
  fi
} > release-notes.md
