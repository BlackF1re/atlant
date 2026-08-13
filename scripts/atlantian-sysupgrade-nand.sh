#!/bin/sh
# NAND edition updater. Debian package updates write to whichever OverlayFS
# upper is active. AtlANTian base/kernel/raw-boot updates are staged onto the
# recovery SD and executed safely from SD maintenance mode.
set -eu

STATE=/var/lib/atlantian/update/available.env
NOTES=/var/lib/atlantian/update/available-notes.txt
RELEASE_CONFIG=${ATLANTIAN_RELEASE_CONFIG:-/etc/atlantian/releases.conf}
RECOVERY_PART=/dev/mmcblk0p2
RUNTIME_EXT=/run/atlantian/external-overlay
STAGE_REL=var/cache/atlantian/nand-target
PREPARED_REL=var/lib/atlantian/nand-target.env
MOUNTED_TEMP=
CARD_ROOT=

get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -n1; }
current() { cat /usr/lib/atlantian/version 2>/dev/null || true; }
major_of() { v=${1%%.*}; case "$v" in ''|*[!0-9]*) return 1;; esac; printf '%s\n' "$v"; }
human_size() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }
record_update_download() {
    # Anonymous aggregate metric. Cache the stable marker with this target so a
    # normal retry/resume of the same NAND transaction does not count again.
    stage=$1
    target=$2
    name=$(get update_name 2>/dev/null || true)
    url=$(get update_url 2>/dev/null || true)
    [ "$name" = atlantian-update.json ] && [ -n "$url" ] || return 0
    marker="$stage/atlantian-update.json"
    if [ -s "$marker" ] && jq -e --arg release "$target" \
        '.schema_version == 1 and .kind == "atlantian-system-update" and .release == $release' \
        "$marker" >/dev/null 2>&1; then
        return 0
    fi
    tmp="$marker.new"
    rm -f "$tmp"
    if ! curl -fL --retry 3 --connect-timeout 20 -sS -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo 'Warning: update activity marker could not be recorded; continuing without telemetry.' >&2
        return 0
    fi
    if ! jq -e --arg release "$target" \
        '.schema_version == 1 and .kind == "atlantian-system-update" and .release == $release' \
        "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo 'Warning: update activity marker was invalid; continuing without telemetry.' >&2
        return 0
    fi
    mv -f "$tmp" "$marker"
}

usage() {
    cat <<'EOF_USAGE'
AtlANTian NAND update model

  Debian packages / ordinary software:
    apt update
    apt upgrade
    # writes to the active upper: internal NAND or adopted recovery-SD upper

  AtlANTian immutable base + kernel + raw boot:
    atlantian-sysupgrade

The full updater downloads the matching NAND bundle onto the AtlANTian recovery
microSD. After moving the physical jumper to SD and rebooting, login starts the
verified maintenance transaction automatically. The raw boot area is read-back
verified, SD Linux rebuilds UBI automatically, and writable layers are reconciled
once against the new immutable base.

Options:
  --check   Show the newest compatible release
  --notes   Show its release notes
  --yes     Stage it without the UPGRADE confirmation
  --help    Show this help
EOF_USAGE
}

cleanup() {
    if [ -n "${MOUNTED_TEMP:-}" ]; then
        umount "$MOUNTED_TEMP" >/dev/null 2>&1 || true
        rmdir "$MOUNTED_TEMP" >/dev/null 2>&1 || true
        MOUNTED_TEMP=
    fi
}
trap cleanup EXIT INT TERM HUP

find_recovery_root() {
    [ -b "$RECOVERY_PART" ] || { echo 'Insert the AtlANTian recovery microSD used for this NAND installation.' >&2; exit 69; }
    /usr/local/sbin/atlantian-storage is-installer-card >/dev/null 2>&1 || {
        echo 'The inserted microSD is not the recovery/install card paired with this NAND installation.' >&2
        exit 65
    }
    if mountpoint -q "$RUNTIME_EXT" && [ "$(findmnt -n -o SOURCE "$RUNTIME_EXT" 2>/dev/null || true)" = "$RECOVERY_PART" ]; then
        CARD_ROOT=$RUNTIME_EXT
    else
        MOUNTED_TEMP=$(mktemp -d /run/atlantian-maintenance-sd.XXXXXX)
        mount -t ext4 -o rw,noatime "$RECOVERY_PART" "$MOUNTED_TEMP"
        CARD_ROOT=$MOUNTED_TEMP
    fi
}

stage_release() {
    target=$(get version)
    tag=$(get tag)
    [ -n "$target" ] && [ -n "$tag" ] || { echo 'release checker did not provide a target release' >&2; exit 65; }
    cur=$(current)
    cur_major=$(major_of "$cur") || { echo "cannot determine installed Debian major from $cur" >&2; exit 65; }
    target_major=$(major_of "$target") || { echo "cannot determine target Debian major from $target" >&2; exit 65; }
    [ "$cur_major" = "$target_major" ] || {
        echo "NAND immutable-base transition $cur_major -> $target_major requires a clean NAND reinstall." >&2
        exit 78
    }

    [ -r "$RELEASE_CONFIG" ] && . "$RELEASE_CONFIG"
    repo=${ATLANTIAN_GITHUB_REPO:-}
    api=${ATLANTIAN_RELEASE_API:-https://api.github.com}
    [ -n "$repo" ] || { echo "ATLANTIAN_GITHUB_REPO is unset in $RELEASE_CONFIG" >&2; exit 64; }
    release_json=$(curl -fsSL --retry 3 "$api/repos/$repo/releases/tags/$tag")
    bundle_name="atlantian-nand-${target}.tar.zst"
    bundle_url=$(printf '%s' "$release_json" | jq -r --arg n "$bundle_name" '.assets[] | select(.name==$n) | .browser_download_url' | head -n1)
    bundle_size=$(printf '%s' "$release_json" | jq -r --arg n "$bundle_name" '.assets[] | select(.name==$n) | .size' | head -n1)
    [ -n "$bundle_url" ] && [ "$bundle_url" != null ] || { echo "release $tag has no $bundle_name" >&2; exit 1; }
    case "$bundle_size" in ''|*[!0-9]*) bundle_size=0 ;; esac

    sums_url=$(get sums_url)
    sums_name=$(get sums_name)
    [ -n "$sums_url" ] && [ "$sums_name" = SHA256SUMS ] || { echo 'release checksum asset metadata is incomplete' >&2; exit 1; }

    find_recovery_root
    stage="$CARD_ROOT/$STAGE_REL/$target"
    bundle_dir="$stage/bundle"
    mkdir -p "$stage" "$bundle_dir" "$CARD_ROOT/var/lib/atlantian"
    record_update_download "$stage" "$target"
    available=$(df -Pk "$CARD_ROOT" | awk 'NR==2 {print $4*1024}')
    required=$((bundle_size + 64*1024*1024))
    [ "$available" -ge "$required" ] || {
        echo "recovery SD lacks staging space: need $(human_size "$required"), have $(human_size "$available")" >&2
        exit 75
    }

    echo "Downloading $bundle_name to the recovery microSD..."
    curl -fL --retry 3 --progress-bar -o "$stage/$bundle_name.new" "$bundle_url"
    mv -f "$stage/$bundle_name.new" "$stage/$bundle_name"
    curl -fL --retry 3 --progress-bar -o "$stage/SHA256SUMS.new" "$sums_url"
    mv -f "$stage/SHA256SUMS.new" "$stage/SHA256SUMS"
    expected=$(awk -v n="$bundle_name" '$2==n {print $1; exit}' "$stage/SHA256SUMS")
    [ -n "$expected" ] || { echo "$bundle_name is absent from release SHA256SUMS" >&2; exit 1; }
    actual=$(sha256sum "$stage/$bundle_name" | awk '{print $1}')
    [ "$actual" = "$expected" ] || { echo 'downloaded NAND bundle checksum mismatch' >&2; exit 1; }

    rm -rf "$bundle_dir"
    mkdir -p "$bundle_dir"
    tar --zstd -xf "$stage/$bundle_name" -C "$bundle_dir"
    [ -s "$bundle_dir/NAND-MANIFEST.json" ] && [ -s "$bundle_dir/SHA256SUMS" ] || { echo 'NAND bundle archive is incomplete' >&2; exit 1; }
    (cd "$bundle_dir" && sha256sum -c SHA256SUMS >/dev/null) || { echo 'internal NAND bundle checksums failed' >&2; exit 1; }
    [ "$(jq -r '.release // empty' "$bundle_dir/NAND-MANIFEST.json")" = "$target" ] || { echo 'NAND bundle release identity mismatch' >&2; exit 1; }

    marker="$CARD_ROOT/$PREPARED_REL"
    tmp="$marker.new"
    printf 'target=%s\nbundle=/%s/%s/bundle\n' "$target" "$STAGE_REL" "$target" >"$tmp"
    mv -f "$tmp" "$marker"
    sync
    echo "Verified NAND update $target is staged on the recovery microSD."
}

[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 77; }
mode=${1:-install}
case "$mode" in --help|-h) usage; exit 0 ;; install|--check|--notes|--yes) ;; *) usage >&2; exit 64 ;; esac
[ "$mode" != install ] || [ $# -eq 0 ] || { usage >&2; exit 64; }

case "$mode" in
    --check|--notes)
        /usr/local/sbin/atlantian-release-check --refresh || exit $?
        if [ -s "$STATE" ]; then
            sed -n 's/^tag=/Latest release: /p;s/^version=/Version: /p;s/^published_at=/Published: /p' "$STATE"
        else
            echo 'No newer compatible AtlANTian release is currently advertised.'
        fi
        if [ "$mode" = --notes ] && [ -s "$NOTES" ]; then echo; sed -n '1,160p' "$NOTES"; fi
        exit 0
        ;;
esac

echo 'Checking published AtlANTian releases...'
/usr/local/sbin/atlantian-release-check --refresh
[ -s "$STATE" ] || { echo 'AtlANTian is already current.'; exit 0; }
cur=$(current); target=$(get version); tag=$(get tag)
echo
echo "AtlANTian NAND base update: $cur -> $target ($tag)"
[ -r "$NOTES" ] && { echo; sed -n '1,100p' "$NOTES"; }
if [ "$mode" != --yes ]; then
    echo
    printf 'Type UPGRADE to download and stage this NAND base update: '
    IFS= read -r answer
    [ "$answer" = UPGRADE ] || { echo 'Cancelled.'; exit 0; }
fi

stage_release
cleanup
trap - EXIT INT TERM HUP
cat <<'EOF_HANDOFF'

The target bundle is safely stored on the recovery microSD.

  1. Move the physical boot-source jumper from NAND to SD.
  2. Press Enter after the jumper is in SD position.

The board will reboot from the same recovery card. At the next root login,
AtlANTian automatically opens the prepared NAND maintenance transaction.
EOF_HANDOFF
IFS= read -r _
sync
systemctl reboot
