#!/usr/bin/env bash
set -euo pipefail
[[ ${ATLANTIAN_TRACE_ROOTFS:-0} = 1 ]] && set -x

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$PROJECT/config/release.env"
. "$PROJECT/config/debian-snapshot.env"
[ -r "$PROJECT/config/local.env" ] && . "$PROJECT/config/local.env"
ROOT="${ROOT:-$PROJECT/out/rootfs}"
SUITE="${SUITE:-$DEBIAN_CODENAME}"
MIRROR="${MIRROR:-$DEBIAN_SNAPSHOT_MIRROR}"
HOSTNAME=${ATLANTIAN_HOSTNAME:-atlantian}
TIMEZONE=${ATLANTIAN_TIMEZONE:-Etc/UTC}
ARCH=armhf
CACHE_DIR=${ATLANTIAN_DEBOOTSTRAP_CACHE:-/var/cache/atlantian/debootstrap}
PACKAGE_LIST=${ATLANTIAN_PACKAGE_LIST:-$PROJECT/config/packages.base}

if [[ ${EUID} -ne 0 ]]; then exec sudo -E "$0" "$@"; fi
[[ -s $PACKAGE_LIST ]] || { echo "factory package profile is missing: $PACKAGE_LIST" >&2; exit 2; }

rm -rf "$ROOT"; mkdir -p "$ROOT" "$CACHE_DIR"
# A GitHub runner can carry a debootstrap package older than the next Debian
# codename. Supplying the generic Debian script keeps future stable codenames
# buildable without weakening the pinned Snapshot input.
DEBOOTSTRAP_SCRIPT=${DEBOOTSTRAP_SCRIPT:-/usr/share/debootstrap/scripts/$SUITE}
if [[ ! -r $DEBOOTSTRAP_SCRIPT ]]; then DEBOOTSTRAP_SCRIPT=/usr/share/debootstrap/scripts/sid; fi
[[ -r $DEBOOTSTRAP_SCRIPT ]] || { echo 'no generic Debian debootstrap script is installed' >&2; exit 2; }
debootstrap --cache-dir="$CACHE_DIR" --arch="$ARCH" --variant=minbase "$SUITE" "$ROOT" "$MIRROR" "$DEBOOTSTRAP_SCRIPT"

cat >"$ROOT/etc/dpkg/dpkg.cfg.d/01-atlantian-lean" <<'EOF_DPKG'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
EOF_DPKG

# The file stored in the image is the profile actually used for this build. A
# NAND build therefore never installs the larger SD profile and purges it later.
install -D -m 0644 "$PACKAGE_LIST" "$ROOT/usr/local/share/atlantian/packages.base"
install -D -m 0644 "$PROJECT/config/image-layout.env" "$ROOT/usr/local/share/atlantian/image-layout.env"

# Factory package selection happens only against immutable Snapshot inputs.
cat >"$ROOT/etc/apt/sources.list" <<EOF_SNAPSHOT_APT
deb [check-valid-until=no] $MIRROR $SUITE main non-free-firmware
deb [check-valid-until=no] $MIRROR ${SUITE}-updates main non-free-firmware
deb [check-valid-until=no] $DEBIAN_SECURITY_SNAPSHOT_MIRROR ${SUITE}-security main non-free-firmware
EOF_SNAPSHOT_APT

printf '%s\n' "$HOSTNAME" >"$ROOT/etc/hostname"
ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$ROOT/etc/localtime"; printf '%s\n' "$TIMEZONE" >"$ROOT/etc/timezone"
cat >"$ROOT/etc/default/locale" <<'EOF_LOCALE'
LANG=C.UTF-8
EOF_LOCALE
cat >"$ROOT/etc/hosts" <<EOF_HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
EOF_HOSTS
cat >"$ROOT/etc/fstab" <<'EOF_FSTAB'
/dev/mmcblk0p2 / ext4 defaults 0 1
/dev/mmcblk0p1 /boot vfat defaults 0 2
EOF_FSTAB

mkdir -p "$ROOT/etc/atlantian" "$ROOT/etc/systemd/network" "$ROOT/etc/systemd/system/serial-getty@ttyPS0.service.d"
cat >"$ROOT/etc/systemd/network/10-atlantian-ethernet.link" <<'EOF_LINK'
[Match]
Driver=macb

[Link]
MACAddressPolicy=persistent
EOF_LINK
cat >"$ROOT/etc/systemd/network/20-ethernet.network" <<'EOF_NETWORK'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF_NETWORK
mkdir -p "$ROOT/etc/systemd/resolved.conf.d"
cat >"$ROOT/etc/systemd/resolved.conf.d/atlantian.conf" <<'EOF_RESOLVED'
[Resolve]
FallbackDNS=1.1.1.1 2606:4700:4700::1111
EOF_RESOLVED
cat >"$ROOT/etc/systemd/system/serial-getty@ttyPS0.service.d/atlantian.conf" <<'EOF_GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400 ttyPS0 vt102
EOF_GETTY

install -d -m 0755 "$ROOT/etc/profile.d" "$ROOT/etc/systemd/logind.conf.d"
cat >>"$ROOT/root/.bashrc" <<'EOF_BASHRC'

if [ -n "${PS1-}" ]; then
    PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
fi
EOF_BASHRC
cat >"$ROOT/root/.profile" <<'EOF_PROFILE'
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF_PROFILE
chmod 0644 "$ROOT/root/.profile"

install -D -m 0755 "$PROJECT/scripts/atlantian-login-info.sh" "$ROOT/usr/local/sbin/atlantian-login-info"
install -D -m 0755 "$PROJECT/scripts/atlantian-fpga.sh" "$ROOT/usr/local/sbin/atlantian-fpga"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-backup.sh" "$ROOT/usr/local/sbin/atlantian-nand-backup"
install -d -m 0755 "$ROOT/lib/firmware/atlantian/status-leds" "$ROOT/etc/atlantian/fpga-profiles.d" "$ROOT/var/lib/atlantian/fpga-profiles"
install -D -m 0644 "$PROJECT/fpga/status-leds/atlantian-status-leds.bin" "$ROOT/lib/firmware/atlantian/status-leds/atlantian-status-leds.bin"
install -D -m 0644 "$PROJECT/fpga/status-leds/atlantian-status-leds.dtbo" "$ROOT/lib/firmware/atlantian/status-leds/atlantian-status-leds.dtbo"
install -D -m 0644 "$PROJECT/fpga/status-leds/manifest.json" "$ROOT/etc/atlantian/fpga-profiles.d/status-leds.json"
cat >"$ROOT/etc/profile.d/10-atlantian-login-info.sh" <<'EOF_LOGIN'
[ -t 1 ] && /usr/local/sbin/atlantian-login-info
EOF_LOGIN
install -D -m 0644 "$PROJECT/systemd/atlantian-power-policy.conf" "$ROOT/etc/systemd/logind.conf.d/atlantian-power-policy.conf"

# Package-owned systemd units are vendor data, not administrator configuration.
# Keep them under /usr/lib/systemd/system so /etc/systemd/system remains available
# for enablement links and deliberate local overrides without dpkg conffile prompts.
install -D -m 0755 "$PROJECT/scripts/atlantian-update-leds.sh" "$ROOT/usr/local/sbin/atlantian-update-leds"
install -D -m 0755 "$PROJECT/scripts/atlantian-status-leds.sh" "$ROOT/usr/local/sbin/atlantian-status-leds"
install -D -m 0644 "$PROJECT/systemd/atlantian-status-leds.service" "$ROOT/usr/lib/systemd/system/atlantian-status-leds.service"
install -D -m 0755 "$PROJECT/scripts/atlantian-fpga-status-leds.sh" "$ROOT/usr/local/sbin/atlantian-fpga-status-leds"
install -D -m 0644 "$PROJECT/systemd/atlantian-fpga-status-leds.service" "$ROOT/usr/lib/systemd/system/atlantian-fpga-status-leds.service"
install -D -m 0755 "$PROJECT/scripts/atlantian-grow-rootfs.sh" "$ROOT/usr/local/sbin/atlantian-grow-rootfs"
install -D -m 0644 "$PROJECT/systemd/atlantian-grow-rootfs.service" "$ROOT/usr/lib/systemd/system/atlantian-grow-rootfs.service"
install -D -m 0755 "$PROJECT/scripts/atlantian-sysupgrade.sh" "$ROOT/usr/local/sbin/atlantian-sysupgrade"
install -D -m 0755 "$PROJECT/scripts/atlantian-release-check.sh" "$ROOT/usr/local/sbin/atlantian-release-check"
install -D -m 0644 "$PROJECT/systemd/atlantian-release-check.service" "$ROOT/usr/lib/systemd/system/atlantian-release-check.service"
install -D -m 0644 "$PROJECT/systemd/atlantian-release-check.timer" "$ROOT/usr/lib/systemd/system/atlantian-release-check.timer"
install -D -m 0644 "$PROJECT/config/atlantian-releases.conf" "$ROOT/etc/atlantian/releases.conf"

mount --bind /dev "$ROOT/dev"; mount -t proc proc "$ROOT/proc"; mount -t sysfs sys "$ROOT/sys"
cleanup() { umount -l "$ROOT/sys" "$ROOT/proc" "$ROOT/dev"; }
trap cleanup EXIT

chroot "$ROOT" /bin/bash -eux <<'EOF_CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Package profiles are human-readable source files: allow blank lines, full-line
# comments and trailing comments, but pass only package tokens to apt. This is
# shared by both SD and NAND profiles so documentation can never become an apt
# argument again.
sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' /usr/local/share/atlantian/packages.base \
  | xargs -r apt-get install -y --no-install-recommends
cat > /etc/default/zramswap <<'EOF_ZRAM'
ALGO=lz4
PERCENT=33
PRIORITY=100
EOF_ZRAM
command -v sfdisk
command -v resize2fs
apt-get clean
rm -rf /var/lib/apt/lists/*
find /usr/share/doc -mindepth 2 -type f ! -name copyright -delete
find /usr/share/doc -depth -type d -empty -delete
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/locale/*
ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable ssh systemd-networkd systemd-timesyncd systemd-resolved \
  serial-getty@ttyPS0.service atlantian-status-leds.service \
  atlantian-fpga-status-leds.service atlantian-grow-rootfs.service \
  zramswap.service atlantian-release-check.timer
systemctl set-default multi-user.target
EOF_CHROOT

: >"$ROOT/etc/machine-id"; rm -f "$ROOT/var/lib/dbus/machine-id"
"$PROJECT/scripts/configure-rootfs-access.sh" "$ROOT"
bash "$PROJECT/scripts/stamp-release.sh" "$ROOT"

mkdir -p "$ROOT/usr/share/atlantian" "$ROOT/usr/lib/atlantian"
chroot "$ROOT" /usr/bin/dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort >"$ROOT/usr/share/atlantian/debian-package-manifest.tsv"
printf 'snapshot=%s\nmirror=%s\nsecurity_mirror=%s\n' \
  "$DEBIAN_SNAPSHOT_TIMESTAMP" "$MIRROR" "$DEBIAN_SECURITY_SNAPSHOT_MIRROR" >"$ROOT/usr/share/atlantian/debian-snapshot.txt"

# Snapshot pinning ends at the build boundary. Runtime APT follows the selected
# Debian codename so installed systems receive updates without crossing a Debian
# major merely because the stable alias moves.
cat >"$ROOT/usr/lib/atlantian/runtime-sources.list" <<EOF_RUNTIME
# Managed by AtlANTian. Put custom repositories in /etc/apt/sources.list.d/.
deb https://deb.debian.org/debian $SUITE main non-free-firmware
deb https://deb.debian.org/debian ${SUITE}-updates main non-free-firmware
deb https://security.debian.org/debian-security ${SUITE}-security main non-free-firmware
EOF_RUNTIME
install -m 0644 "$ROOT/usr/lib/atlantian/runtime-sources.list" "$ROOT/etc/apt/sources.list"
if grep -q 'snapshot.debian.org' "$ROOT/etc/apt/sources.list"; then echo 'runtime APT sources must not point at snapshot.debian.org' >&2; exit 1; fi

grep -qxF "deb https://deb.debian.org/debian $SUITE main non-free-firmware" "$ROOT/etc/apt/sources.list"
grep -qxF "deb https://deb.debian.org/debian ${SUITE}-updates main non-free-firmware" "$ROOT/etc/apt/sources.list"
grep -qxF "deb https://security.debian.org/debian-security ${SUITE}-security main non-free-firmware" "$ROOT/etc/apt/sources.list"

cleanup; trap - EXIT
echo "rootfs created: $ROOT"
