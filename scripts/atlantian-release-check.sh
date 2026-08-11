#!/bin/sh
# Discover the newest complete AtlANTian release reachable by the supported
# Debian upgrade path. Same-major releases are offered before the next major.
set -eu

RELEASE_CONFIG=${ATLANTIAN_RELEASE_CONFIG:-/etc/atlantian/releases.conf}
[ -r "$RELEASE_CONFIG" ] && . "$RELEASE_CONFIG"
REPO=${ATLANTIAN_GITHUB_REPO:-}
API=${ATLANTIAN_RELEASE_API:-https://api.github.com}
STATE_DIR=/var/lib/atlantian/update
STATE_FILE=$STATE_DIR/available.env
NOTES_FILE=$STATE_DIR/available-notes.txt
MAX_RELEASE_PAGES=${ATLANTIAN_RELEASE_PAGES:-30}

get() { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n1; }
current() { cat /usr/lib/atlantian/version 2>/dev/null || true; }
major_of() {
  value=${1%%.*}
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}
ordering_version() {
  value=$1
  case "$value" in
    [0-9]*.[0-9]*.[0-9]*-*)
      core=${value%%-*}
      prerelease=${value#*-}
      printf '%s~%s\n' "$core" "$prerelease"
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}
package_version_of() {
  value=$1
  case "$value" in
    [0-9]*.[0-9]*.[0-9]*-*)
      core=${value%%-*}
      prerelease=${value#*-}
      printf '%s~%s-1\n' "$core" "$prerelease"
      ;;
    *) printf '%s-1\n' "$value" ;;
  esac
}
newer() { dpkg --compare-versions "$(ordering_version "$1")" gt "$(ordering_version "$2")"; }
clear_state() { rm -f "$STATE_FILE" "$NOTES_FILE"; }
asset() {
  release_json=$1
  asset_name=$2
  printf '%s' "$release_json" | jq -r --arg name "$asset_name" \
    '.assets[] | select(.name == $name) | [.name, .browser_download_url, .size] | @tsv' | head -n1
}
package_asset() {
  release_json=$1 release_version=$2 package=$3 arch=$4
  package_version=$(package_version_of "$release_version")
  asset "$release_json" "${package}_${package_version}_${arch}.deb"
}
complete_release() {
  release_json=$1 release_version=$2
  [ -n "$(package_asset "$release_json" "$release_version" atlantian-platform all)" ] && \
  [ -n "$(package_asset "$release_json" "$release_version" atlantian-kernel armhf)" ] && \
  [ -n "$(package_asset "$release_json" "$release_version" atlantian-release all)" ] && \
  [ -n "$(asset "$release_json" SHA256SUMS)" ]
}

notice() {
  [ -r "$STATE_FILE" ] || exit 0
  version=$(get version); tag=$(get tag); installed=$(current)
  [ -n "$version" ] && [ -n "$installed" ] && newer "$version" "$installed" || { clear_state; exit 0; }
  printf '\nUpdate is available: %s\nRun: atlantian-sysupgrade\n\n' "$tag"
}

case "${1:---refresh}" in --notice) notice; exit 0 ;; --refresh) ;; *) echo 'usage: atlantian-release-check [--refresh|--notice]' >&2; exit 64 ;; esac
[ -n "$REPO" ] || { echo "ATLANTIAN_GITHUB_REPO is unset; set it in $RELEASE_CONFIG" >&2; exit 64; }
command -v jq >/dev/null || { echo 'jq is required for release metadata parsing' >&2; exit 69; }
command -v dpkg >/dev/null || { echo 'dpkg is required for release version comparison' >&2; exit 69; }
case "$MAX_RELEASE_PAGES" in ''|*[!0-9]*) echo 'ATLANTIAN_RELEASE_PAGES must be numeric' >&2; exit 64 ;; esac
[ "$MAX_RELEASE_PAGES" -gt 0 ] || { echo 'ATLANTIAN_RELEASE_PAGES must be greater than zero' >&2; exit 64; }

installed=$(current)
[ -n "$installed" ] || { echo 'AtlANTian release identity is missing' >&2; exit 65; }
installed_major=$(major_of "$installed") || { echo "invalid installed AtlANTian version: $installed" >&2; exit 65; }
case "$installed" in *-*) allow_prerelease=true ;; *) allow_prerelease=false ;; esac
best_same= best_same_version= best_next= best_next_version=
page=1
while [ "$page" -le "$MAX_RELEASE_PAGES" ]; do
  page_json=$(curl -fsSL --retry 3 "$API/repos/$REPO/releases?per_page=100&page=$page")
  count=$(printf '%s' "$page_json" | jq 'length')
  [ "$count" -gt 0 ] || break

  tags=$(printf '%s' "$page_json" | jq -r '.[] | select(.draft == false) | .tag_name // empty')
  for tag in $tags; do
    case "$tag" in v*) version=${tag#v} ;; *) continue ;; esac
    release_json=$(printf '%s' "$page_json" | jq -c --arg tag "$tag" '.[] | select(.tag_name == $tag)' | head -n1)
    [ -n "$release_json" ] || continue
    is_prerelease=$(printf '%s' "$release_json" | jq -r '.prerelease')
    [ "$is_prerelease" != true ] || [ "$allow_prerelease" = true ] || continue
    [ -z "$installed" ] || newer "$version" "$installed" || continue
    candidate_major=$(major_of "$version" 2>/dev/null || true)
    [ -n "$candidate_major" ] || continue
    complete_release "$release_json" "$version" || continue

    if [ "$candidate_major" -eq "$installed_major" ]; then
      if [ -z "$best_same_version" ] || newer "$version" "$best_same_version"; then
        best_same=$release_json; best_same_version=$version
      fi
    elif [ "$candidate_major" -eq $((installed_major + 1)) ]; then
      if [ -z "$best_next_version" ] || newer "$version" "$best_next_version"; then
        best_next=$release_json; best_next_version=$version
      fi
    fi
  done

  [ "$count" -eq 100 ] || break
  page=$((page + 1))
done

if [ -n "$best_same" ]; then
  json=$best_same
elif [ -n "$best_next" ]; then
  json=$best_next
else
  clear_state
  echo "No newer compatible AtlANTian release found for installed version $installed."
  exit 0
fi

tag=$(printf '%s' "$json" | jq -r '.tag_name // empty')
published=$(printf '%s' "$json" | jq -r '.published_at // empty')
notes=$(printf '%s' "$json" | jq -r '.body // "No release notes were published."')
case "$tag" in v*) version=${tag#v} ;; *) echo "invalid AtlANTian release tag: $tag" >&2; exit 1 ;; esac
platform=$(package_asset "$json" "$version" atlantian-platform all)
kernel=$(package_asset "$json" "$version" atlantian-kernel armhf)
releasepkg=$(package_asset "$json" "$version" atlantian-release all)
sums=$(asset "$json" SHA256SUMS)
[ -n "$platform" ] && [ -n "$kernel" ] && [ -n "$releasepkg" ] && [ -n "$sums" ] || { echo 'selected release has no complete, version-matched package set' >&2; exit 1; }

tab=$(printf '\t')
IFS="$tab" read -r platform_name platform_url platform_size <<EOF_PLATFORM
$platform
EOF_PLATFORM
IFS="$tab" read -r kernel_name kernel_url kernel_size <<EOF_KERNEL
$kernel
EOF_KERNEL
IFS="$tab" read -r release_name release_url release_size <<EOF_RELEASE
$releasepkg
EOF_RELEASE
IFS="$tab" read -r sums_name sums_url sums_size <<EOF_SUMS
$sums
EOF_SUMS

mkdir -p "$STATE_DIR"
tmp=$(mktemp "$STATE_DIR/.available.XXXXXX"); notes_tmp=$(mktemp "$STATE_DIR/.notes.XXXXXX")
trap 'rm -f "$tmp" "$notes_tmp"' EXIT
printf '%s\n' "$notes" >"$notes_tmp"
printf 'version=%s\nrelease_id=%s\ntag=%s\npublished_at=%s\nplatform_name=%s\nplatform_url=%s\nplatform_size=%s\nkernel_name=%s\nkernel_url=%s\nkernel_size=%s\nrelease_name=%s\nrelease_url=%s\nrelease_size=%s\nsums_name=%s\nsums_url=%s\nsums_size=%s\n' \
  "$version" "$version" "$tag" "$published" \
  "$platform_name" "$platform_url" "$platform_size" \
  "$kernel_name" "$kernel_url" "$kernel_size" \
  "$release_name" "$release_url" "$release_size" \
  "$sums_name" "$sums_url" "$sums_size" >"$tmp"
mv "$tmp" "$STATE_FILE"; mv "$notes_tmp" "$NOTES_FILE"
echo "AtlANTian update available: $installed -> $tag"
