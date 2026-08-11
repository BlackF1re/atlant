#!/usr/bin/env bash
# Refresh the immutable Snapshot backing the configured Debian generation.
# Routine Debian repository changes never alter the AtlANTian release version.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT"
. config/release.env

ARCH=armhf
SUITE=$DEBIAN_CODENAME
MAJOR=$DEBIAN_MAJOR
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'Debian refresh: %s\n' "$*" >&2; exit 1; }
field() { awk -F': ' -v key="$2" '$1 == key { print $2; exit }' "$1"; }
has_arch() {
  local arches
  arches=$(field "$1" Architectures)
  [[ " $arches " == *" $ARCH "* ]]
}
major_of_release() {
  local version
  version=$(field "$1" Version)
  [[ $version =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  printf '%s\n' "${version%%.*}"
}
fetch() { curl -fsSL --retry 3 --connect-timeout 20 "$1" -o "$2"; }
emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
}

[[ $SUITE =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail 'configured Debian codename is invalid'
[[ $MAJOR =~ ^[0-9]+$ ]] || fail 'configured Debian major is invalid'
[[ $ARCH == armhf ]] || fail 'configured Debian architecture must be armhf'

major_available=false
candidate_major=
candidate_codename=
next_major=$((MAJOR + 1))
for alias in stable oldstable oldoldstable; do
  alias_file="$WORK/$alias"
  fetch "https://deb.debian.org/debian/dists/$alias/Release" "$alias_file" 2>/dev/null || continue
  found_major=$(major_of_release "$alias_file" 2>/dev/null || true)
  found_codename=$(field "$alias_file" Codename)
  [[ $found_major == "$next_major" ]] || continue
  [[ $found_codename =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
  has_arch "$alias_file" || continue
  major_available=true
  candidate_major=$found_major
  candidate_codename=$found_codename
  break
done
emit major_available "$major_available"
if [[ $major_available == true ]]; then
  emit candidate_major "$candidate_major"
  emit candidate_codename "$candidate_codename"
  echo "Debian $candidate_major ($candidate_codename) is available for an explicit AtlANTian release-line transition."
fi

updates_suite=${SUITE}-updates
security_suite=${SUITE}-security
main_live="$WORK/live-main"
updates_live="$WORK/live-updates"
security_live="$WORK/live-security"

fetch "https://deb.debian.org/debian/dists/$SUITE/Release" "$main_live" || fail "cannot fetch configured Debian $SUITE repository"
fetch "https://deb.debian.org/debian/dists/$updates_suite/Release" "$updates_live" || fail "cannot fetch configured Debian $updates_suite repository"
fetch "https://security.debian.org/debian-security/dists/$security_suite/Release" "$security_live" || fail "cannot fetch configured Debian $security_suite repository"

[[ $(field "$main_live" Codename) == "$SUITE" ]] || fail 'main Release codename mismatch'
[[ $(major_of_release "$main_live") == "$MAJOR" ]] || fail 'main Release version mismatch'
[[ $(field "$updates_live" Codename) == "$updates_suite" ]] || fail 'updates Release codename mismatch'
[[ $(field "$security_live" Codename) == "$security_suite" ]] || fail 'security Release codename mismatch'
for file in "$main_live" "$updates_live" "$security_live"; do has_arch "$file" || fail "configured Debian suite stopped publishing $ARCH"; done

for tuple in \
  "https://deb.debian.org/debian/dists/$SUITE/main/binary-$ARCH/Release $WORK/arch-main" \
  "https://deb.debian.org/debian/dists/$updates_suite/main/binary-$ARCH/Release $WORK/arch-updates" \
  "https://security.debian.org/debian-security/dists/$security_suite/main/binary-$ARCH/Release $WORK/arch-security"; do
  set -- $tuple
  fetch "$1" "$2" || fail "binary-$ARCH archive is unavailable for configured Debian"
done

current_main_sha=$(sha256sum "$main_live" | awk '{print $1}')
current_updates_sha=$(sha256sum "$updates_live" | awk '{print $1}')
current_security_sha=$(sha256sum "$security_live" | awk '{print $1}')
old_main_sha=$(tr -d '\r\n' < debian-release.sha256)
old_updates_sha=$(tr -d '\r\n' < debian-updates-release.sha256)
old_security_sha=$(tr -d '\r\n' < debian-security-release.sha256)
if [[ $current_main_sha == "$old_main_sha" && $current_updates_sha == "$old_updates_sha" && $current_security_sha == "$old_security_sha" ]]; then
  emit changed false
  exit 0
fi

timestamps=$(curl -fsSL --retry 3 --connect-timeout 20 https://snapshot.debian.org/mr/timestamp/)
main_timestamp=$(printf '%s' "$timestamps" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["debian"][-1])')
security_timestamp=$(printf '%s' "$timestamps" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["debian-security"][-1])')
snapshot_url="https://snapshot.debian.org/archive/debian/${main_timestamp}"
security_snapshot_url="https://snapshot.debian.org/archive/debian-security/${security_timestamp}"

fetch "$snapshot_url/dists/$SUITE/Release" "$WORK/snapshot-main" || { emit changed false; exit 0; }
fetch "$snapshot_url/dists/$updates_suite/Release" "$WORK/snapshot-updates" || { emit changed false; exit 0; }
fetch "$security_snapshot_url/dists/$security_suite/Release" "$WORK/snapshot-security" || { emit changed false; exit 0; }

snapshot_main_sha=$(sha256sum "$WORK/snapshot-main" | awk '{print $1}')
snapshot_updates_sha=$(sha256sum "$WORK/snapshot-updates" | awk '{print $1}')
snapshot_security_sha=$(sha256sum "$WORK/snapshot-security" | awk '{print $1}')
if [[ $snapshot_main_sha != "$current_main_sha" || $snapshot_updates_sha != "$current_updates_sha" || $snapshot_security_sha != "$current_security_sha" ]]; then
  echo 'Debian Snapshot has not caught up with the observed repositories; retrying on the next run.'
  emit changed false
  exit 0
fi

printf '%s\n' "$snapshot_main_sha" > debian-release.sha256
printf '%s\n' "$snapshot_updates_sha" > debian-updates-release.sha256
printf '%s\n' "$snapshot_security_sha" > debian-security-release.sha256
cat > config/debian-snapshot.env <<EOF_SNAPSHOT
# Reproducible Debian rootfs input. Updated only after Snapshot contains the
# exact live repository metadata selected by refresh-debian-base.sh.
DEBIAN_SNAPSHOT_TIMESTAMP=$main_timestamp
DEBIAN_SNAPSHOT_MIRROR=$snapshot_url
DEBIAN_SECURITY_SNAPSHOT_MIRROR=$security_snapshot_url
EOF_SNAPSHOT

emit changed true
emit codename "$SUITE"
emit major "$MAJOR"
emit snapshot "$main_timestamp"
echo "Frozen Debian $MAJOR ($SUITE) / $ARCH at $main_timestamp; AtlANTian remains $ATLANTIAN_VERSION."
