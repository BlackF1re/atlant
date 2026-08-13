#!/usr/bin/env bash
# Normalize a verified local artifact directory into the exact GitHub Release
# payload while leaving the sealed Actions artifact itself untouched on GitHub.
# Debian package metadata keeps '~' ordering; public filenames use '.'.
set -euo pipefail

DIR=${1:?verified artifact directory}
METADATA="$DIR/RELEASE-METADATA.json"
[[ -s $METADATA ]] || { echo "public release payload: missing $METADATA" >&2; exit 1; }

mapfile -t values < <(python3 - "$METADATA" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    m = json.load(stream)
print(m['release'])
print(m['package_version'])
print(m['image'])
PY
)
RELEASE=${values[0]}
PACKAGE_VERSION=${values[1]}
RAW_IMAGE_NAME=${values[2]}
PUBLIC_PACKAGE_VERSION=${PACKAGE_VERSION//\~/.}

fail() { printf 'public release payload: %s\n' "$*" >&2; exit 1; }
need_file() { [[ -s $1 ]] || fail "missing file: $1"; }

RAW_IMAGE="$DIR/$RAW_IMAGE_NAME"
IMAGE="$DIR/${RAW_IMAGE_NAME}.xz"
NAND="$DIR/atlantian-nand-$RELEASE.tar.zst"
need_file "$RAW_IMAGE"
need_file "$IMAGE"
need_file "$NAND"

xz -t "$IMAGE"
raw_sha=$(sha256sum "$RAW_IMAGE" | awk '{print $1}')
decoded_sha=$(xz -dc "$IMAGE" | sha256sum | awk '{print $1}')
[[ $decoded_sha == "$raw_sha" ]] || fail 'compressed image does not decode to the verified raw image'

normalize_package() {
  local package=$1 arch=$2 canonical public file
  canonical="$DIR/${package}_${PACKAGE_VERSION}_${arch}.deb"
  public="$DIR/${package}_${PUBLIC_PACKAGE_VERSION}_${arch}.deb"

  if [[ -s $canonical ]]; then
    file=$canonical
  elif [[ -s $public ]]; then
    file=$public
  else
    fail "missing $package package for Debian version $PACKAGE_VERSION"
  fi
  [[ $(dpkg-deb -f "$file" Package) == "$package" ]] || fail "$file has the wrong Package field"
  [[ $(dpkg-deb -f "$file" Version) == "$PACKAGE_VERSION" ]] || fail "$file has the wrong Version field"
  [[ $(dpkg-deb -f "$file" Architecture) == "$arch" ]] || fail "$file has the wrong Architecture field"

  if [[ $canonical != "$public" && $file == "$canonical" ]]; then
    rm -f "$public"
    mv "$canonical" "$public"
  fi
}

normalize_package atlantian-platform all
normalize_package atlantian-kernel armhf
normalize_package atlantian-release all

python3 - "$RELEASE" >"$DIR/atlantian-update.json" <<'PY'
import json
import sys
json.dump({
    "schema_version": 1,
    "kind": "atlantian-system-update",
    "release": sys.argv[1],
}, sys.stdout, separators=(",", ":"))
sys.stdout.write("\n")
PY

# The public checksum manifest names exactly the files users can download. The
# server-side sealed Actions artifact retains the original manifest containing
# the raw image and canonical Debian filenames.
(
  cd "$DIR"
  sha256sum \
    "${RAW_IMAGE_NAME}.xz" \
    "atlantian-kernel_${PUBLIC_PACKAGE_VERSION}_armhf.deb" \
    "atlantian-nand-$RELEASE.tar.zst" \
    "atlantian-platform_${PUBLIC_PACKAGE_VERSION}_all.deb" \
    "atlantian-release_${PUBLIC_PACKAGE_VERSION}_all.deb" \
    atlantian-update.json \
    RELEASE-METADATA.json > SHA256SUMS
)

echo "Prepared public release payload in $DIR"
