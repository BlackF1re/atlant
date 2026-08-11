#!/bin/sh
# Install/finish AtlANTian for NAND from the ordinary AtlANTian SD system.
# Safety ordering is deliberate:
#   backup -> raw boot program/verify in SD U-Boot -> automatic SD Linux resume
#   -> UBI program/verify -> physical jumper handoff.
set -eu

BUNDLE=${ATLANTIAN_NAND_BUNDLE:-/usr/lib/atlantian/nand}
STATE=/var/lib/atlantian/nand-install
PENDING=$STATE/pending
READY=$STATE/ready-to-handoff
UPGRADE_SAVE=/var/cache/atlantian/nand-overlay-preserve
BACKUP_DEFAULT=/root/atlantian-factory-nand-backup
BOOT=/boot
MASTER_NAME=pl35x-nand-controller
MASTER=
UBI_MTD=
ROOT_UBI_VOL=

usage() {
    cat <<'EOF_USAGE'
Usage:
  atlantian-nand-install [--backup DIR]
  atlantian-nand-install --resume
  atlantian-nand-install --resume-auto
  atlantian-nand-install --handoff

Normal installation is intentionally one-command:
  1. boot the normal AtlANTian image from microSD with the jumper in SD mode;
  2. run `atlantian-nand-install` and confirm the destructive operation once;
  3. the board reboots once in SD mode and completes NAND formatting/writing;
  4. reconnect when prompted, move the jumper SD -> NAND and press Enter.

`--resume` is a recovery/manual continuation path. `--resume-auto` is reserved
for the systemd continuation service.
EOF_USAGE
}

fatal() { echo "atlantian-nand-install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"; }
step() { printf '\n==> %s\n' "$*"; }

lock_install() {
    need flock
    mkdir -p /run/lock
    exec 9>/run/lock/atlantian-nand-install.lock
    flock -n 9 || fatal 'another NAND install/upgrade process is already running'
}

find_master() {
    line=$(awk -F: -v n="\"$MASTER_NAME\"" '$2 ~ n {gsub(/[[:space:]]/, "", $1); print $1; found++} END {if (found != 1) exit 1}' /proc/mtd) \
        || fatal "expected exactly one whole $MASTER_NAME MTD device"
    MASTER=/dev/$line
    [ -c "$MASTER" ] || fatal "missing $MASTER"
}

verify_host() {
    [ "$(id -u)" -eq 0 ] || fatal 'run as root'
    model=$(tr -d '\000' </proc/device-tree/model 2>/dev/null || true)
    case "$model" in *Antminer*S9*) ;; *) fatal "unsupported board model: $model" ;; esac
    case "$(findmnt -n -o SOURCE / 2>/dev/null || true)" in /dev/mmcblk0p2) ;; *) fatal 'NAND maintenance must be run while booted from the AtlANTian microSD root' ;; esac
}

verify_platform() {
    verify_host
    for c in jq sha256sum mtdpart ubiformat ubiattach ubidetach ubimkvol ubiupdatevol ubiblock ubinfo nanddump mount umount findmnt rsync atlantian-nand-rebase; do need "$c"; done
    [ -s "$BUNDLE/NAND-MANIFEST.json" ] && [ -s "$BUNDLE/SHA256SUMS" ] || fatal "NAND payload is missing under $BUNDLE"
    (cd "$BUNDLE" && sha256sum -c SHA256SUMS >/dev/null) || fatal 'embedded NAND payload checksum verification failed'
    [ "$(jq -r .compression.rootfs_squashfs "$BUNDLE/NAND-MANIFEST.json")" = zstd ] || fatal 'unexpected immutable SquashFS compression policy'
    [ "$(jq -r .compression.overlay_ubifs "$BUNDLE/NAND-MANIFEST.json")" = lzo ] || fatal 'unexpected writable UBIFS compression policy'
    [ "$(jq -r .volumes.rootfs.type "$BUNDLE/NAND-MANIFEST.json")" = static ] || fatal 'rootfs UBI volume must be static'
    [ "$(jq -r .volumes.rootfs.filesystem "$BUNDLE/NAND-MANIFEST.json")" = squashfs ] || fatal 'rootfs filesystem must be SquashFS'
    find_master

    mtd=${MASTER##*/}
    size=$(cat "/sys/class/mtd/$mtd/size")
    erase=$(cat "/sys/class/mtd/$mtd/erasesize")
    write=$(cat "/sys/class/mtd/$mtd/writesize")
    oob=$(cat "/sys/class/mtd/$mtd/oobsize")
    [ "$size" = 268435456 ] || fatal "unexpected NAND size: $size"
    [ "$erase" = 131072 ] || fatal "unexpected erase size: $erase"
    [ "$write" = 2048 ] || fatal "unexpected NAND page size: $write"
    [ "$oob" = 64 ] || fatal "unexpected NAND OOB size: $oob"

    # Linux owns only the UBI data region and deliberately uses BCH there. UBI
    # then owns bad-block management and wear-leveling above the MTD layer.
    strength=$(cat "/sys/class/mtd/$mtd/ecc_strength" 2>/dev/null || echo 0)
    ecc_step=$(cat "/sys/class/mtd/$mtd/ecc_step_size" 2>/dev/null || echo 0)
    [ "$strength" -ge 4 ] && [ "$ecc_step" = 512 ] || fatal "Linux NAND data ECC is $strength/$ecc_step; expected BCH >=4/512"
}

valid_backup() {
    d=$1
    [ -s "$d/NAND-INFO.txt" ] && [ -s "$d/nand-raw-oob.bin" ] && [ -s "$d/SHA256SUMS" ] \
        && (cd "$d" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
}

ensure_backup() {
    backup=$1
    step '[1/4] Backing up the existing NAND'
    if valid_backup "$backup"; then
        echo "Using verified existing factory backup: $backup"
    else
        echo "Creating and verifying a raw+OOB factory backup at: $backup"
        atlantian-nand-backup "$backup"
        valid_backup "$backup" || fatal 'factory backup did not verify'
    fi
    echo "Factory backup verified: $backup"
    echo 'Keep a copy on another computer before reusing/erasing this microSD if factory restore matters to you.'
}

stage_raw_boot() {
    mode=$1
    target=$(jq -r .release "$BUNDLE/NAND-MANIFEST.json")
    id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [ ${#id} -eq 32 ] || fatal 'cannot create installer identity'

    step '[2/4] Staging the verified raw boot transaction'
    mountpoint -q "$BOOT" || mount /dev/mmcblk0p1 "$BOOT"
    install -m 0644 "$BUNDLE/spl-redundant.bin" "$BOOT/atln-spl.bin"
    install -m 0644 "$BUNDLE/u-boot.img" "$BOOT/atln-uboot.img"
    install -m 0644 "$BUNDLE/uImage" "$BOOT/atln-kernel.img"
    install -m 0644 "$BUNDLE/uInitrd" "$BOOT/atln-initrd.img"
    install -m 0644 "$BUNDLE/devicetree.dtb" "$BOOT/atln-dtb.bin"
    install -m 0644 "$BUNDLE/nand-stage.scr" "$BOOT/atln-stage.scr"
    printf '%s\n' "$id" >"$BOOT/atln-install.id"
    rm -f "$BOOT/atln-stage.done"
    mkdir -p "$STATE"
    printf 'installer_id=%s\nrelease=%s\nmode=%s\n' "$id" "$target" "$mode" >"$PENDING"
    rm -f "$READY"
    sync

    cat <<'EOF_STAGE'
The board will now reboot ONCE while the jumper remains in SD mode.
SD U-Boot will erase/program/read-back the raw 16 MiB boot area. AtlANTian will
then boot from SD again and automatically finish the UBI installation.

DO NOT move the boot jumper yet.
EOF_STAGE
    sync
    systemctl reboot
}

find_ubi_volume() {
    wanted=$1
    found=
    for d in /sys/class/ubi/ubi0_*; do
        [ -r "$d/name" ] || continue
        [ "$(cat "$d/name")" = "$wanted" ] || continue
        [ -z "$found" ] || fatal "multiple UBI volumes named $wanted"
        found=${d##*/}
    done
    [ -n "$found" ] || fatal "UBI volume not found: $wanted"
    printf '%s\n' "$found"
}

remove_root_ubiblock() {
    [ -n "${ROOT_UBI_VOL:-}" ] || return 0
    ubiblock --remove "/dev/$ROOT_UBI_VOL" >/dev/null 2>&1 || true
    ROOT_UBI_VOL=
}

cleanup_ubi() {
    set +e
    for p in /run/atlantian-install-overlay /run/atlantian-install-root; do mountpoint -q "$p" && umount "$p"; done
    remove_root_ubiblock
    [ -n "${UBI_MTD:-}" ] && ubidetach -p "$UBI_MTD" >/dev/null 2>&1
    set -e
}

create_ubi_partition() {
    existing=$(awk -F: '$2 ~ /"atlantian-ubi"/ {gsub(/[[:space:]]/, "", $1); print "/dev/" $1; found++} END {if (found > 1) exit 1}' /proc/mtd) \
        || fatal 'multiple dynamic atlantian-ubi partitions exist'
    if [ -n "$existing" ]; then
        UBI_MTD=$existing
        return
    fi

    ubi_offset=$(jq -r .nand.ubi_offset_bytes "$BUNDLE/NAND-MANIFEST.json")
    ubi_size=$((268435456 - ubi_offset))
    mtdpart add "$MASTER" atlantian-ubi "$ubi_offset" "$ubi_size"
    UBI_MTD=$(awk -F: '$2 ~ /"atlantian-ubi"/ {gsub(/[[:space:]]/, "", $1); print "/dev/" $1; found++} END {if (found != 1) exit 1}' /proc/mtd) \
        || fatal 'dynamic atlantian-ubi partition did not appear'
}

validate_rebase_snapshot() {
    [ -s "$UPGRADE_SAVE/TRANSACTION" ] || fatal 'preserved upgrade transaction metadata is missing'
    [ "$(sed -n 's/^rebase_schema=//p' "$UPGRADE_SAVE/TRANSACTION" | head -n1)" = 1 ] \
        || fatal 'preserved upgrade rebase schema is unsupported'
    [ -s "$UPGRADE_SAVE/internal/METADATA" ] && [ -d "$UPGRADE_SAVE/internal/delta" ] \
        || fatal 'internal rebase snapshot is incomplete'

    external_layout=$(sed -n 's/^external_layout=//p' "$UPGRADE_SAVE/TRANSACTION" | head -n1)
    case "$external_layout" in
        none|'') ;;
        recovery-p2)
            [ -s "$UPGRADE_SAVE/external/METADATA" ] && [ -d "$UPGRADE_SAVE/external/delta" ] \
                || fatal 'external rebase snapshot is incomplete'
            [ -s "$UPGRADE_SAVE/.extroot-token" ] && [ -s /.atlantian-extroot/token ] \
                || fatal 'external recovery-card adoption token is missing'
            [ "$(cat /.atlantian-extroot/token)" = "$(cat "$UPGRADE_SAVE/.extroot-token")" ] \
                || fatal 'external recovery-card token changed during upgrade'
            ;;
        *) fatal "unsupported preserved external overlay layout: $external_layout" ;;
    esac
}

write_ubi() {
    mode=$1
    id=$2
    root_bytes=$(jq -r .volumes.rootfs.bytes "$BUNDLE/NAND-MANIFEST.json")
    root_image_bytes=$(jq -r .volumes.rootfs.image_bytes "$BUNDLE/NAND-MANIFEST.json")
    min_overlay=$(jq -r .volumes.overlay.minimum_lebs "$BUNDLE/NAND-MANIFEST.json")
    leb=$(jq -r .nand.leb_bytes "$BUNDLE/NAND-MANIFEST.json")
    target=$(jq -r .release "$BUNDLE/NAND-MANIFEST.json")

    # Fail closed before ubiformat: an upgrade may replace UBI only when every
    # snapshot needed to construct fresh internal/external uppers is already
    # present on the recovery SD.
    [ "$mode" != upgrade ] || validate_rebase_snapshot

    step '[3/4] Formatting and writing the UBI data region'
    create_ubi_partition
    trap cleanup_ubi EXIT INT TERM HUP
    ubidetach -p "$UBI_MTD" >/dev/null 2>&1 || true
    echo 'Formatting only the Linux UBI region after the raw boot area has verified...'
    ubiformat "$UBI_MTD" -y
    ubiattach -p "$UBI_MTD"

    # Static UBI is ideal for an immutable compressed image: UBI still handles
    # bad blocks and wear-level placement, while SquashFS itself has no journal
    # or writable metadata. The UBIFS upper receives every ordinary Debian write.
    ubimkvol /dev/ubi0 -N rootfs -t static -s "$root_bytes"
    root_vol=$(find_ubi_volume rootfs)
    ubiupdatevol "/dev/$root_vol" "$BUNDLE/rootfs.squashfs"
    [ "$(cat "/sys/class/ubi/$root_vol/type")" = static ] || fatal 'written rootfs UBI volume is not static'
    data_bytes=$(cat "/sys/class/ubi/$root_vol/data_bytes")
    [ "$data_bytes" = "$root_image_bytes" ] || fatal "static rootfs data size mismatch: expected $root_image_bytes, got $data_bytes"

    ubimkvol /dev/ubi0 -N overlay -m
    overlay_vol=$(find_ubi_volume overlay)
    # UBI sysfs is a stable machine-readable ABI. For dynamic volumes data_bytes
    # is the total volume size, unlike the human-readable ubinfo output whose
    # formatting may include an additional MiB field.
    overlay_bytes=$(cat "/sys/class/ubi/$overlay_vol/data_bytes" 2>/dev/null || true)
    case "$overlay_bytes" in
        ''|*[!0-9]*) fatal 'cannot determine overlay volume size from UBI sysfs' ;;
    esac
    [ "$overlay_bytes" -ge $((min_overlay * leb)) ] || fatal 'actual NAND bad blocks leave less than the required internal overlay reserve'

    mkdir -p /run/atlantian-install-root /run/atlantian-install-overlay
    ROOT_UBI_VOL=$root_vol
    ubiblock --create "/dev/$root_vol"
    root_block=/dev/ubiblock${root_vol#ubi}
    n=0
    while [ ! -b "$root_block" ] && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
    [ -b "$root_block" ] || fatal "ubiblock device did not appear: $root_block"
    mount -t squashfs -o ro,nodev "$root_block" /run/atlantian-install-root
    actual=$(cat /run/atlantian-install-root/usr/lib/atlantian/version 2>/dev/null || true)
    [ "$actual" = "$target" ] || fatal "written rootfs release mismatch: expected $target, got $actual"

    # An empty dynamic UBI volume is formatted by the first writable UBIFS mount.
    # During upgrade, it stays empty until state is replayed through OverlayFS
    # against the verified target lower; package files/whiteouts are not copied.
    mount -t ubifs -o rw,noatime,compr=lzo ubi0:overlay /run/atlantian-install-overlay
    mkdir -p /run/atlantian-install-overlay/upper /run/atlantian-install-overlay/work
    if [ "$mode" = upgrade ]; then
        atlantian-nand-rebase restore "$UPGRADE_SAVE/internal" \
            /run/atlantian-install-root \
            /run/atlantian-install-overlay/upper \
            /run/atlantian-install-overlay/work "$target"
        [ -s "$UPGRADE_SAVE/.extroot-token" ] \
            && cp -a "$UPGRADE_SAVE/.extroot-token" /run/atlantian-install-overlay/.extroot-token || true

        external_layout=$(sed -n 's/^external_layout=//p' "$UPGRADE_SAVE/TRANSACTION" | head -n1)
        case "$external_layout" in
            none|'') ;;
            recovery-p2)
                [ -s /.atlantian-extroot/token ] \
                    && [ "$(cat /.atlantian-extroot/token)" = "$(cat "$UPGRADE_SAVE/.extroot-token")" ] \
                    || fatal 'external recovery-card token changed during upgrade'
                # Snapshot is durable on the same SD. Recreate both OverlayFS
                # directories so package whiteouts/workdir state are not carried
                # into the target base.
                rm -rf /.atlantian-extroot/upper /.atlantian-extroot/work
                mkdir -p /.atlantian-extroot/upper /.atlantian-extroot/work
                atlantian-nand-rebase restore "$UPGRADE_SAVE/external" \
                    /run/atlantian-install-root \
                    /.atlantian-extroot/upper /.atlantian-extroot/work "$target"
                ;;
            *) fatal "unsupported preserved external overlay layout: $external_layout" ;;
        esac
    else
        mkdir -p /run/atlantian-install-overlay/upper/var/lib/atlantian/nand
        printf '%s\n' "$id" >/run/atlantian-install-overlay/upper/var/lib/atlantian/nand/installer-id
        : >/run/atlantian-install-overlay/upper/var/lib/atlantian/nand/offer-extroot
    fi
    sync
    umount /run/atlantian-install-overlay
    umount /run/atlantian-install-root
    remove_root_ubiblock
    ubidetach -p "$UBI_MTD"
    UBI_MTD=
    trap - EXIT INT TERM HUP
    [ "$mode" = upgrade ] && rm -rf "$UPGRADE_SAVE"

    echo "Verified static SquashFS rootfs $target; internal writable UBIFS overlay bytes: $overlay_bytes"
}

finish_resume() {
    mode=$1
    id=$2
    target=$3

    # Disable the destructive one-shot only after UBI has also verified. If UBI
    # creation fails, atln-stage.done makes subsequent SD boots skip rewriting
    # raw NAND while preserving the exact payloads for diagnosis/retry.
    rm -f "$BOOT/atln-stage.scr" "$BOOT/atln-stage.done" \
      "$BOOT/atln-spl.bin" "$BOOT/atln-uboot.img" "$BOOT/atln-kernel.img" \
      "$BOOT/atln-initrd.img" "$BOOT/atln-dtb.bin"

    tmp=$READY.new
    printf 'installer_id=%s\nrelease=%s\nmode=%s\n' "$id" "$target" "$mode" >"$tmp"
    mv -f "$tmp" "$READY"
    rm -f "$PENDING"
    [ "$mode" = upgrade ] && rm -f /var/lib/atlantian/nand-target.env
    sync

    step '[4/4] NAND installation is complete and verified'
    echo 'Raw boot, static SquashFS lower and writable UBIFS overlay all passed verification.'
}

resume() {
    auto=${1:-no}
    if [ -s "$PENDING" ]; then
        pending_bundle=$(sed -n 's/^bundle=//p' "$PENDING" | head -n1)
        if [ -n "$pending_bundle" ]; then
            case "$pending_bundle" in /var/cache/atlantian/nand-target/*/bundle) BUNDLE=$pending_bundle ;; *) fatal 'unsafe pending NAND bundle path' ;; esac
        fi
    fi
    verify_platform

    if [ -s "$READY" ] && [ ! -s "$PENDING" ]; then
        [ "$auto" = yes ] && exit 0
        handoff
        return
    fi

    [ -s "$PENDING" ] || fatal 'no pending NAND installation/upgrade exists'
    mountpoint -q "$BOOT" || mount /dev/mmcblk0p1 "$BOOT"
    [ -s "$BOOT/atln-stage.done" ] || fatal 'SD U-Boot did not leave a verified NAND-stage marker; KEEP JUMPER IN SD MODE and inspect UART'
    id=$(sed -n 's/^installer_id=//p' "$PENDING" | head -n1)
    mode=$(sed -n 's/^mode=//p' "$PENDING" | head -n1)
    target=$(sed -n 's/^release=//p' "$PENDING" | head -n1)
    case "$mode" in fresh|upgrade) ;; *) fatal "invalid pending NAND mode: $mode" ;; esac
    [ -n "$id" ] && [ -r "$BOOT/atln-install.id" ] && [ "$(cat "$BOOT/atln-install.id")" = "$id" ] \
        || fatal 'installer-card identity mismatch'

    echo 'Raw boot region passed the final U-Boot read-back; continuing automatically in SD mode.'
    write_ubi "$mode" "$id"
    finish_resume "$mode" "$id" "$target"

    if [ "$auto" = yes ]; then
        echo 'Reconnect/login to AtlANTian. It will ask for the final SD -> NAND jumper handoff.'
        return
    fi
    handoff
}

handoff() {
    verify_host
    [ -s "$READY" ] || fatal 'NAND has not completed verified installation yet'

    cat <<'EOF_HANDOFF'

NAND is ready to boot.

  1. LEAVE the AtlANTian microSD inserted for now.
  2. Physically move the boot-source jumper from SD to NAND.
  3. Press Enter only after the jumper is in the NAND position.

The jumper is sampled by hardware at reset; there is no software substitute for
this final physical step.
EOF_HANDOFF
    if ! IFS= read -r _; then
        echo 'Handoff postponed. Run `atlantian-nand-install --handoff` when ready.'
        return 0
    fi

    rm -f "$READY"
    sync
    echo 'Rebooting into NAND. The microSD remains intact as recovery media and can later be adopted as the external writable layer.'
    if ! systemctl reboot; then
        : >"$READY"
        sync
        fatal 'reboot request failed; handoff state restored'
    fi
}

mode=install
backup=$BACKUP_DEFAULT
while [ $# -gt 0 ]; do
    case "$1" in
        --resume) mode=resume; shift ;;
        --resume-auto) mode=resume-auto; shift ;;
        --handoff) mode=handoff; shift ;;
        --backup) [ $# -ge 2 ] || { usage >&2; exit 64; }; backup=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done

lock_install
case "$mode" in
    resume) resume no; exit ;;
    resume-auto) resume yes; exit ;;
    handoff) handoff; exit ;;
esac

verify_platform
if [ -s "$READY" ]; then handoff; exit; fi
if [ -s "$PENDING" ]; then
    echo 'A NAND transaction is already pending. AtlANTian normally resumes it automatically after the SD reboot.'
    echo 'For manual recovery run: atlantian-nand-install --resume'
    exit 75
fi

cat <<'EOF_INTRO'
AtlANTian NAND installer
------------------------
This converts the on-board 256 MiB raw NAND into:
  - a verified 16 MiB raw boot area,
  - a BCH-protected UBI static volume with Zstd SquashFS immutable base, and
  - an LZO-compressed UBIFS writable OverlayFS upper using all remaining space.

The currently installed NAND contents will be destroyed. The microSD system
itself is not erased and remains bootable for recovery.
EOF_INTRO
ensure_backup "$backup"

echo
printf 'FINAL DESTRUCTIVE CONFIRMATION: type INSTALL to replace the on-board NAND: '
IFS= read -r answer
[ "$answer" = INSTALL ] || { echo 'Cancelled; NAND was not modified.'; exit 0; }
stage_raw_boot fresh
