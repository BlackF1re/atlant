#!/usr/bin/env bash
# Validate the public AtlANTian release model and Debian package ordering without
# building any image or contacting the network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
. config/release.env

fail() { printf 'release versioning contract: %s\n' "$*" >&2; exit 1; }

[[ $DEBIAN_MAJOR =~ ^[0-9]+$ ]] || fail 'Debian major must be numeric'
[[ $ATLANTIAN_MINOR =~ ^[0-9]+$ ]] || fail 'AtlANTian minor must be numeric'
[[ $ATLANTIAN_PATCH =~ ^[0-9]+$ ]] || fail 'AtlANTian patch must be numeric'
[[ $ATLANTIAN_DEBIAN_REVISION =~ ^[1-9][0-9]*$ ]] || fail 'Debian package revision must be positive'

core="${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${ATLANTIAN_PATCH}"
[[ $ATLANTIAN_VERSION_CORE == "$core" ]] || fail 'release core is not derived from Debian major + AtlANTian minor/patch'
case "$ATLANTIAN_PRERELEASE" in
  '')
    [[ $ATLANTIAN_VERSION == "$core" ]] || fail 'stable release contains unexpected suffix'
    [[ $ATLANTIAN_DEB_VERSION == "$core-$ATLANTIAN_DEBIAN_REVISION" ]] || fail 'stable Debian package version mismatch'
    ;;
  *)
    [[ $ATLANTIAN_PRERELEASE =~ ^[0-9A-Za-z]+([.-][0-9A-Za-z]+)*$ ]] || fail 'invalid prerelease identifier'
    [[ $ATLANTIAN_VERSION == "$core-$ATLANTIAN_PRERELEASE" ]] || fail 'prerelease version mismatch'
    [[ $ATLANTIAN_DEB_VERSION == "$core~$ATLANTIAN_PRERELEASE-$ATLANTIAN_DEBIAN_REVISION" ]] || fail 'prerelease Debian package version mismatch'
    ;;
esac

[[ $ATLANTIAN_RELEASE_ID == "atlantian-$ATLANTIAN_VERSION" ]] || fail 'release ID contains non-release metadata'
[[ $ATLANTIAN_IMAGE_NAME == "$ATLANTIAN_RELEASE_ID" ]] || fail 'image identity must equal the release identity'
[[ $ATLANTIAN_SOURCE_ID == "$ATLANTIAN_VERSION+g$ATLANTIAN_SOURCE_REVISION" ]] || fail 'source identity must carry Git metadata separately'
[[ $ATLANTIAN_VERSION != *+g* ]] || fail 'Git revision leaked into semantic release version'
[[ $ATLANTIAN_DEB_VERSION != *+g* ]] || fail 'Git revision leaked into Debian package version'

versions=(
  '13.1.0~alpha.1-1'
  '13.1.0~alpha.2-1'
  '13.1.0~beta.1-1'
  '13.1.0~rc.1-1'
  '13.1.0-1'
  '13.1.1-1'
  '13.2.0-1'
  '14.1.0-1'
)
for ((i=0; i<${#versions[@]}-1; i++)); do
  dpkg --compare-versions "${versions[$i]}" lt "${versions[$((i+1))]}" \
    || fail "Debian ordering is invalid: ${versions[$i]} !< ${versions[$((i+1))]}"
done

printf 'release versioning passed: release=%s package=%s source=%s image=%s kernel=%s%s\n' \
  "$ATLANTIAN_VERSION" "$ATLANTIAN_DEB_VERSION" "$ATLANTIAN_SOURCE_ID" "$ATLANTIAN_IMAGE_NAME" \
  "$ATLANTIAN_KERNEL_VERSION" "$ATLANTIAN_KERNEL_LOCALVERSION"
