#!/usr/bin/env bash
# Exercise release discovery against the exact public asset naming contract.
# This catches the distinction between AtlANTian release versions, Debian package
# versions and GitHub-safe .deb filenames before an expensive image build starts.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$ROOT/scripts/atlantian-release-check.sh"
fail() { printf 'release client contract: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"
cat >"$tmp/bin/curl" <<'EOF_CURL'
#!/bin/sh
cat "$ATLANTIAN_TEST_RELEASES_JSON"
EOF_CURL
chmod +x "$tmp/bin/curl"
cat >"$tmp/releases.conf" <<'EOF_CONFIG'
ATLANTIAN_GITHUB_REPO=test-owner/test-repo
ATLANTIAN_RELEASE_API=https://example.invalid
ATLANTIAN_RELEASE_PAGES=1
EOF_CONFIG

asset_json() {
  local name=$1 size=${2:-123}
  jq -cn --arg name "$name" --arg url "https://example.invalid/$name" --argjson size "$size" \
    '{name:$name,browser_download_url:$url,size:$size}'
}
release_json() {
  local version=$1 prerelease=$2 package_file_version=$3
  local platform kernel release sums marker
  platform=$(asset_json "atlantian-platform_${package_file_version}_all.deb")
  kernel=$(asset_json "atlantian-kernel_${package_file_version}_armhf.deb")
  release=$(asset_json "atlantian-release_${package_file_version}_all.deb")
  sums=$(asset_json SHA256SUMS)
  marker=$(asset_json atlantian-update.json 81)
  jq -cn \
    --arg tag "v$version" --arg published '2026-08-14T00:00:00Z' \
    --argjson prerelease "$prerelease" \
    --argjson platform "$platform" --argjson kernel "$kernel" \
    --argjson release "$release" --argjson sums "$sums" --argjson marker "$marker" \
    '{tag_name:$tag,draft:false,prerelease:$prerelease,published_at:$published,body:"fixture",assets:[$platform,$kernel,$release,$sums,$marker]}'
}
run_case() {
  local installed=$1 candidate=$2 prerelease=$3 public_package_version=$4 expected_deb_version=$5
  rm -rf "$tmp/state" && mkdir -p "$tmp/state"
  printf '%s\n' "$installed" >"$tmp/version"
  release_json "$candidate" "$prerelease" "$public_package_version" | jq -s . >"$tmp/releases.json"

  PATH="$tmp/bin:$PATH" \
  ATLANTIAN_TEST_RELEASES_JSON="$tmp/releases.json" \
  ATLANTIAN_RELEASE_CONFIG="$tmp/releases.conf" \
  ATLANTIAN_UPDATE_STATE_DIR="$tmp/state" \
  ATLANTIAN_VERSION_FILE="$tmp/version" \
    sh "$CHECKER" --refresh >/dev/null

  state="$tmp/state/available.env"
  [[ -s $state ]] || fail "$installed -> $candidate produced no update state"
  grep -qx "version=$candidate" "$state" || fail "$candidate release version was not selected"
  grep -qx "package_version=$expected_deb_version" "$state" || fail "$candidate Debian package version was not preserved"
  grep -qx "platform_name=atlantian-platform_${public_package_version}_all.deb" "$state" || fail "$candidate platform asset name mismatch"
  grep -qx "kernel_name=atlantian-kernel_${public_package_version}_armhf.deb" "$state" || fail "$candidate kernel asset name mismatch"
  grep -qx "release_name=atlantian-release_${public_package_version}_all.deb" "$state" || fail "$candidate release-package asset name mismatch"
}

# Current GitHub-safe prerelease filenames use '.' while package metadata uses '~'.
run_case 13.1.0-alpha.6 13.1.0-alpha.7 true 13.1.0.alpha.7-3 13.1.0~alpha.7-3
# Stable release filenames and Debian package versions differ by the Debian revision.
run_case 13.1.0 13.1.1 false 13.1.1-2 13.1.1-2
# Mirrors that preserve canonical '~' filenames remain discoverable as a fallback.
run_case 13.1.0-alpha.7 13.1.0-alpha.8 true '13.1.0~alpha.8-4' '13.1.0~alpha.8-4'

echo 'prerelease, stable and canonical-mirror release discovery contracts passed'
