#!/bin/sh
# Interactive, Debian-style in-place AtlANTian system updater.
set -eu

STATE=${ATLANTIAN_UPDATE_STATE:-/var/lib/atlantian/update/available.env}
NOTES=${ATLANTIAN_UPDATE_NOTES:-/var/lib/atlantian/update/available-notes.txt}
MAJOR_PENDING=${ATLANTIAN_MAJOR_PENDING:-/var/lib/atlantian/update/major-upgrade-pending.env}
STAGE=${ATLANTIAN_UPDATE_STAGE:-/var/cache/atlantian/update}
VERSION_FILE=${ATLANTIAN_VERSION_FILE:-/usr/lib/atlantian/version}
RELEASE_CONFIG=${ATLANTIAN_RELEASE_CONFIG:-/etc/atlantian/releases.conf}
LED_HELPER=/usr/local/sbin/atlantian-update-leds
LED_LOCK=/run/atlantian-update-leds.lock
LED_SERVICES='atlantian-status-leds.service atlantian-fpga-status-leds.service'
MAJOR_MIN_FREE_BYTES=${ATLANTIAN_MAJOR_UPGRADE_MIN_FREE_BYTES:-536870912}
MAJOR_AUTH=/run/atlantian-major-upgrade-authorized
ledpid=

get() { sed -n "s/^$1=//p" "$STATE" | head -n1; }
pending_get() { sed -n "s/^$1=//p" "$MAJOR_PENDING" | head -n1; }
current() { cat "$VERSION_FILE" 2>/dev/null || printf unknown; }
major_of() {
  value=${1%%.*}
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}
package_version_matches_release() {
  package_version=$1
  release_version=$2
  case "$release_version" in
    [0-9]*.[0-9]*.[0-9]*-*)
      core=${release_version%%-*}
      prerelease=${release_version#*-}
      prefix="${core}~${prerelease}-"
      ;;
    *) prefix="${release_version}-" ;;
  esac
  case "$package_version" in
    "$prefix"*) revision=${package_version#"$prefix"} ;;
    *) return 1 ;;
  esac
  case "$revision" in ''|*[!0-9]*) return 1 ;; esac
  [ "$revision" -gt 0 ]
}
human_size() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }
record_update_download() {
  # Anonymous aggregate metric: one tiny, stable Release asset is fetched when a
  # real update transaction starts. It carries no device identifier and is
  # cached per target so a normal resume/retry does not count again.
  name=$(get update_name 2>/dev/null || true)
  url=$(get update_url 2>/dev/null || true)
  [ "$name" = atlantian-update.json ] && [ -n "$url" ] || return 0
  version=$(get version)
  marker=$STAGE/atlantian-update.json
  if [ -s "$marker" ] && jq -e --arg release "$version" \
    '.schema_version == 1 and .kind == "atlantian-system-update" and .release == $release' \
    "$marker" >/dev/null 2>&1; then
    return 0
  fi
  tmp=$marker.new
  rm -f "$tmp"
  if ! curl -fL --retry 3 --connect-timeout 20 -sS -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo 'Warning: update activity marker could not be recorded; continuing without telemetry.' >&2
    return 0
  fi
  if ! jq -e --arg release "$version" \
    '.schema_version == 1 and .kind == "atlantian-system-update" and .release == $release' \
    "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo 'Warning: update activity marker was invalid; continuing without telemetry.' >&2
    return 0
  fi
  mv -f "$tmp" "$marker"
}
apt_full_upgrade() {
  apt-get update
  apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' full-upgrade -y
}
usage() {
  cat <<'EOF_USAGE'
Usage: atlantian-sysupgrade [OPTION]

Without an option, checks GitHub Releases, shows the newest reachable release
and asks for UPGRADE before installing it.

Options:
  --check       Refresh and show whether an update is available.
  --notes       Refresh and print the newest release notes.
  --yes         Install/resume without interactive confirmation.
  --help        Show this help.
EOF_USAGE
  printf '\nRelease source configuration: %s\n' "$RELEASE_CONFIG"
}
show_release() {
  total=$(( $(get platform_size) + $(get kernel_size) + $(get release_size) ))
  installed=$(current)
  target=$(get version)
  installed_major=$(major_of "$installed" 2>/dev/null || true)
  target_major=$(major_of "$target" 2>/dev/null || true)
  cat <<EOF_SHOW

AtlANTian update available
  Installed: $installed
  Release:   $(get tag)
  Published: $(get published_at)
  Download:  $(human_size "$total") (three verified Debian packages)
EOF_SHOW
  if [ -n "$installed_major" ] && [ -n "$target_major" ] && [ "$target_major" -gt "$installed_major" ]; then
    printf '  Debian:    major upgrade %s -> %s\n' "$installed_major" "$target_major"
  fi
  printf '\nChanges:\n'
  [ -r "$NOTES" ] && sed -n '1,120p' "$NOTES" || echo '  No release notes were published.'
}
find_staged_package() {
  package=$1
  arch=$2
  release_version=$3
  found=
  for file in "$STAGE"/"${package}_"*.deb; do
    [ -f "$file" ] || continue
    [ "$(dpkg-deb -f "$file" Package 2>/dev/null || true)" = "$package" ] || continue
    actual_version=$(dpkg-deb -f "$file" Version 2>/dev/null || true)
    package_version_matches_release "$actual_version" "$release_version" || continue
    [ "$(dpkg-deb -f "$file" Architecture 2>/dev/null || true)" = "$arch" ] || continue
    [ -z "$found" ] || return 1
    found=$file
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
verify_staged_version() {
  release_version=$1
  [ -s "$STAGE/SHA256SUMS" ] || return 1
  verified_package_version=

  for spec in 'atlantian-platform all' 'atlantian-kernel armhf' 'atlantian-release all'; do
    set -- $spec
    package=$1
    arch=$2
    file=$(find_staged_package "$package" "$arch" "$release_version") || return 1
    package_version=$(dpkg-deb -f "$file" Version 2>/dev/null || true)
    [ -n "$package_version" ] || return 1
    if [ -z "$verified_package_version" ]; then
      verified_package_version=$package_version
    else
      [ "$verified_package_version" = "$package_version" ] || return 1
    fi
    name=$(basename "$file")
    canonical_name="${package}_${package_version}_${arch}.deb"

    # New releases checksum the exact public filename. Historical prereleases
    # may have GitHub-normalized '.' asset names while SHA256SUMS still contains
    # Debian's canonical '~' filename, so accept either name for that same file.
    expected=$(awk -v public="$name" -v canonical="$canonical_name" \
      '$2 == public || $2 == canonical { print $1; exit }' "$STAGE/SHA256SUMS")
    [ -n "$expected" ] || return 1
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$expected" ] || return 1
    dpkg-deb --info "$file" >/dev/null || return 1
  done

  if [ -r "$STATE" ] && [ "$(get version 2>/dev/null || true)" = "$release_version" ]; then
    advertised=$(get package_version 2>/dev/null || true)
    [ -z "$advertised" ] || [ "$advertised" = "$verified_package_version" ] || return 1
  fi
}
download_and_verify() {
  mkdir -p "$STAGE"
  rm -f "$STAGE"/*.deb "$STAGE/SHA256SUMS"
  record_update_download
  total=$(( $(get platform_size) + $(get kernel_size) + $(get release_size) ))
  available=$(df -Pk "$STAGE" | awk 'NR == 2 { print $4 * 1024 }')
  required=$((total + 32 * 1024 * 1024))
  [ "$available" -ge "$required" ] || {
    echo "not enough free space in $STAGE: need $(human_size "$required"), have $(human_size "$available")" >&2
    exit 75
  }
  for prefix in platform kernel release; do
    url=$(get "${prefix}_url")
    name=$(get "${prefix}_name")
    case "$name" in ''|*[!A-Za-z0-9._+~-]*) echo "unsafe release asset name: $name" >&2; exit 65 ;; esac
    echo "Downloading $name"
    curl -fL --retry 3 --progress-bar -o "$STAGE/$name" "$url"
  done
  echo "Downloading $(get sums_name)"
  curl -fL --retry 3 --progress-bar -o "$STAGE/SHA256SUMS" "$(get sums_url)"
  release_version=$(get version)
  verify_staged_version "$release_version" || { echo 'package checksum/version verification failed' >&2; exit 1; }
  echo 'All packages are verified.'
}
ensure_pending_packages() {
  target=$1
  if verify_staged_version "$target"; then
    echo "Using the already verified staged package set for $target."
    return
  fi
  if [ -r "$STATE" ] && [ "$(get version)" = "$target" ]; then
    echo "Re-downloading the pending package set for $target."
    download_and_verify
    return
  fi
  echo "cannot resume $target: its verified package set is no longer staged" >&2
  echo 'Restore /var/cache/atlantian/update or clear the pending state only after manual recovery.' >&2
  exit 75
}
restore_update_leds() {
  if [ -n "${ledpid:-}" ]; then
    kill "$ledpid" 2>/dev/null || true
    wait "$ledpid" 2>/dev/null || true
    ledpid=
  fi
  rm -f "$LED_LOCK" "$MAJOR_AUTH"
  systemctl start $LED_SERVICES >/dev/null 2>&1 || true
}
start_update_leds() {
  [ -x "$LED_HELPER" ] || { echo "update LED helper is unavailable: $LED_HELPER" >&2; exit 69; }
  ATLANTIAN_UPDATE_RESTART_SERVICES=0 "$LED_HELPER" &
  ledpid=$!
  sleep 0.2
  kill -0 "$ledpid" 2>/dev/null || {
    wait "$ledpid" 2>/dev/null || true
    ledpid=
    echo 'update LED indicator failed to start' >&2
    exit 70
  }
}
disable_third_party_sources() {
  target_version=$1
  backup=/var/lib/atlantian/update/apt-sources-before-$target_version
  mkdir -p "$backup/sources.list.d"
  if [ -e /etc/apt/sources.list ] && [ ! -e "$backup/sources.list" ]; then
    cp -a /etc/apt/sources.list "$backup/sources.list"
  fi
  for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -e "$file" ] || continue
    mv "$file" "$backup/sources.list.d/"
  done
  printf '%s\n' "$backup" > /var/lib/atlantian/update/major-upgrade-sources-backup
  echo "Third-party APT sources were backed up under $backup and disabled for the Debian major upgrade."
}
install_packaged_sources() {
  template=/usr/lib/atlantian/runtime-sources.list
  [ -s "$template" ] || { echo 'release package has no managed Debian repository template' >&2; exit 1; }
  install -m 0644 "$template" /etc/apt/sources.list
}
write_major_pending() {
  target_version=$1
  target_major=$2
  mkdir -p "$(dirname "$MAJOR_PENDING")"
  tmp=${MAJOR_PENDING}.tmp
  printf 'target_version=%s\ntarget_major=%s\n' "$target_version" "$target_major" >"$tmp"
  mv "$tmp" "$MAJOR_PENDING"
}
install_staged_packages() {
  target_version=$1
  authorize_major=${2:-false}
  verify_staged_version "$target_version" || { echo 'staged package set is not verified' >&2; exit 1; }
  platform=$(find_staged_package atlantian-platform all "$target_version") || exit 1
  kernel=$(find_staged_package atlantian-kernel armhf "$target_version") || exit 1
  releasepkg=$(find_staged_package atlantian-release all "$target_version") || exit 1

  if [ "$authorize_major" = true ]; then
    printf '%s\n' "$target_version" >"$MAJOR_AUTH"
  fi
  apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' install -y \
    "$platform" "$kernel" "$releasepkg"
  rm -f "$MAJOR_AUTH"
}
check_dpkg_state() {
  audit=$(dpkg --audit 2>&1 || true)
  [ -z "$audit" ] || { printf '%s\n' "$audit" >&2; echo 'dpkg reports an incomplete package state' >&2; exit 1; }
}
reboot_now() {
  sync
  echo 'Update complete. Rebooting now; this SSH session will close.'
  trap - EXIT INT TERM HUP
  set +e
  systemctl reboot
  reboot_status=$?
  set -e
  if [ "$reboot_status" -ne 0 ]; then
    trap restore_update_leds EXIT
    echo "failed to request reboot (systemctl exit $reboot_status)" >&2
    exit "$reboot_status"
  fi
  wait "$ledpid" || true
}
resume_major_upgrade() {
  target_version=$(pending_get target_version)
  target_major=$(pending_get target_major)
  [ -n "$target_version" ] && [ -n "$target_major" ] || { echo 'invalid major-upgrade pending state' >&2; exit 65; }
  case "$target_major" in *[!0-9]*|'') echo 'invalid pending Debian major' >&2; exit 65 ;; esac

  echo "A Debian-major transition to AtlANTian $target_version is pending and must be completed first."
  if [ "$mode" = --check ] || [ "$mode" = --notes ]; then
    echo 'Run atlantian-sysupgrade to resume it.'
    exit 0
  fi
  if [ "$mode" != --yes ]; then
    printf 'Type RESUME to continue the interrupted major upgrade: '
    IFS= read -r answer
    [ "$answer" = RESUME ] || { echo 'Resume cancelled.'; exit 0; }
  fi

  trap restore_update_leds EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  start_update_leds
  ensure_pending_packages "$target_version"
  install_staged_packages "$target_version" true
  [ "$(cat /usr/lib/atlantian/version 2>/dev/null || true)" = "$target_version" ] || {
    echo 'installed AtlANTian version marker does not match the pending release' >&2; exit 1;
  }
  [ "$(cat /usr/lib/atlantian/debian-major 2>/dev/null || true)" = "$target_major" ] || {
    echo 'installed release Debian-major marker mismatch' >&2; exit 1;
  }
  install_packaged_sources
  echo "Resuming Debian userspace upgrade to major $target_major..."
  apt_full_upgrade
  check_dpkg_state
  rm -f "$MAJOR_PENDING"
  reboot_now
}

if [ "${ATLANTIAN_SYSUPGRADE_LIBRARY_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

[ "$(id -u)" = 0 ] || { echo 'run as root' >&2; exit 77; }
mode=${1:-install}
case "$mode" in --help|-h) usage; exit 0 ;; install|--check|--notes|--yes) ;; *) usage >&2; exit 64 ;; esac
[ "$mode" != install ] || [ $# -eq 0 ] || { usage >&2; exit 64; }
rm -f "$MAJOR_AUTH"

if [ -s "$MAJOR_PENDING" ]; then
  resume_major_upgrade
  exit 0
fi

echo 'Checking published AtlANTian releases...'
/usr/local/sbin/atlantian-release-check --refresh
[ -r "$STATE" ] || { echo 'AtlANTian is already current.'; exit 0; }
show_release
[ "$mode" = --check ] && exit 0
[ "$mode" = --notes ] && exit 0

installed_version=$(current)
target_version=$(get version)
installed_major=$(major_of "$installed_version" 2>/dev/null || true)
target_major=$(major_of "$target_version" 2>/dev/null || true)
[ -n "$installed_major" ] && [ -n "$target_major" ] || { echo 'cannot determine Debian major from release versions' >&2; exit 65; }
[ "$target_major" -ge "$installed_major" ] || { echo 'refusing Debian-major downgrade' >&2; exit 65; }
[ "$target_major" -le $((installed_major + 1)) ] || { echo "refusing to skip Debian majors: $installed_major -> $target_major" >&2; exit 65; }
major_upgrade=false
[ "$target_major" -gt "$installed_major" ] && major_upgrade=true
if [ "$major_upgrade" = true ]; then
  free=$(df -Pk / | awk 'NR == 2 { print $4 * 1024 }')
  [ "$free" -ge "$MAJOR_MIN_FREE_BYTES" ] || {
    echo "Debian major upgrade needs at least $(human_size "$MAJOR_MIN_FREE_BYTES") free on /; have $(human_size "$free")" >&2
    exit 75
  }
fi

if [ "$mode" != --yes ]; then
  cat <<'EOF_CONFIRM'

The update keeps ordinary Debian state: /etc, SSH keys, /root, /home, /var and
installed packages. A Debian major upgrade temporarily disables third-party APT
sources and keeps a backup so incompatible repositories cannot contaminate the
transition. Interrupted major upgrades are recorded and can be resumed safely.
The board reboots when the update finishes.

Type UPGRADE to download and install this release:
EOF_CONFIRM
  IFS= read -r answer
  [ "$answer" = UPGRADE ] || { echo 'Update cancelled.'; exit 0; }
fi

trap restore_update_leds EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
start_update_leds
download_and_verify
export DEBIAN_FRONTEND=noninteractive

if [ "$major_upgrade" = true ]; then
  disable_third_party_sources "$target_version"
  if [ -s /usr/lib/atlantian/runtime-sources.list ]; then install_packaged_sources; fi
  echo "Fully upgrading Debian $installed_major before the major transition..."
  apt_full_upgrade
  check_dpkg_state
  write_major_pending "$target_version" "$target_major"
fi

echo 'Installing AtlANTian platform, kernel and release packages...'
if [ "$major_upgrade" = true ]; then
  install_staged_packages "$target_version" true
else
  install_staged_packages "$target_version" false
fi
[ "$(cat /usr/lib/atlantian/version 2>/dev/null || true)" = "$target_version" ] || {
  echo 'installed AtlANTian version marker does not match the selected release' >&2; exit 1;
}

if [ "$major_upgrade" = true ]; then
  [ "$(cat /usr/lib/atlantian/debian-major 2>/dev/null || true)" = "$target_major" ] || {
    echo 'installed release Debian-major marker mismatch' >&2; exit 1;
  }
  install_packaged_sources
  echo "Upgrading Debian userspace to major $target_major..."
else
  echo 'Refreshing current Debian repositories...'
fi
apt_full_upgrade
check_dpkg_state
[ "$major_upgrade" = false ] || rm -f "$MAJOR_PENDING"
reboot_now
