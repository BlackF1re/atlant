#!/usr/bin/env bash
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$PROJECT/config/release.env"
. "$PROJECT/config/debian-snapshot.env"
. "$PROJECT/config/atlantian-releases.conf"
ROOT=${1:?usage: stamp-release.sh ROOTFS}
[[ -d "$ROOT/etc" ]] || { echo "not a root filesystem: $ROOT" >&2; exit 2; }
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$ROOT"

ATLANTIAN_GITHUB_WEB=${ATLANTIAN_GITHUB_WEB:-https://github.com}
ATLANTIAN_REPO_URL="$ATLANTIAN_GITHUB_WEB/$ATLANTIAN_GITHUB_REPO"

install -d -m 0755 "$ROOT/usr/lib/atlantian"
printf '%s\n' "$ATLANTIAN_VERSION" >"$ROOT/usr/lib/atlantian/version"
printf '%s\n' "$ATLANTIAN_DEB_VERSION" >"$ROOT/usr/lib/atlantian/package-version"
printf '%s\n' "$ATLANTIAN_SOURCE_REVISION" >"$ROOT/usr/lib/atlantian/source-revision"
printf '%s\n' "$DEBIAN_CODENAME" >"$ROOT/usr/lib/atlantian/debian-codename"
printf '%s\n' "$DEBIAN_MAJOR" >"$ROOT/usr/lib/atlantian/debian-major"
printf '%s\n' "$DEBIAN_SNAPSHOT_TIMESTAMP" >"$ROOT/usr/lib/atlantian/debian-snapshot"
printf '%s\n' "$ATLANTIAN_GITHUB_REPO" >"$ROOT/usr/lib/atlantian/release-repo"

# Generic Linux tooling should see a Debian system, while the human-facing name
# and VARIANT fields retain the AtlANTian distribution identity. This avoids
# fragile third-party installers that ignore ID_LIKE and key only on ID=debian.
cat >"$ROOT/usr/lib/atlantian/os-release" <<EOF_OS
PRETTY_NAME="AtlANTian GNU/Linux $ATLANTIAN_VERSION (Debian $DEBIAN_MAJOR $DEBIAN_CODENAME)"
NAME="Debian GNU/Linux"
ID=debian
VERSION_ID="$DEBIAN_MAJOR"
VERSION="$DEBIAN_MAJOR ($DEBIAN_CODENAME)"
VERSION_CODENAME="$DEBIAN_CODENAME"
VARIANT="AtlANTian GNU/Linux"
VARIANT_ID=atlantian
BUILD_ID="$ATLANTIAN_SOURCE_ID"
ATLANTIAN_VERSION="$ATLANTIAN_VERSION"
ATLANTIAN_PACKAGE_VERSION="$ATLANTIAN_DEB_VERSION"
ATLANTIAN_SOURCE_REVISION="$ATLANTIAN_SOURCE_REVISION"
ATLANTIAN_DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT_TIMESTAMP"
ATLANTIAN_RELEASE_REPOSITORY="$ATLANTIAN_GITHUB_REPO"
HOME_URL="$ATLANTIAN_REPO_URL"
DOCUMENTATION_URL="$ATLANTIAN_REPO_URL#readme"
SUPPORT_URL="$ATLANTIAN_REPO_URL/issues"
BUG_REPORT_URL="$ATLANTIAN_REPO_URL/issues"
EOF_OS
install -m 0644 "$ROOT/usr/lib/atlantian/os-release" "$ROOT/etc/os-release"

cat >"$ROOT/etc/issue.net" <<EOF_ISSUE
AtlANTian GNU/Linux $ATLANTIAN_VERSION
Debian $DEBIAN_MAJOR ($DEBIAN_CODENAME)

The programs included with Debian are free software; their distribution terms
are described in the corresponding copyright files under /usr/share/doc.

Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent permitted by
applicable law.
EOF_ISSUE
