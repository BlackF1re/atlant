#!/usr/bin/env bash
# Provision the appliance-style root account. The initial image deliberately
# has an empty root password; the profile warning remains until `passwd` is run.
set -euo pipefail

ROOT=${1:?usage: configure-rootfs-access.sh ROOTFS}
ATLANTIAN_DEPLOY_KEY_FILE=${ATLANTIAN_DEPLOY_KEY_FILE:-}

[[ $EUID -eq 0 ]] || exec sudo "$0" "$ROOT"
[[ -d "$ROOT/etc" ]] || { echo "not a root filesystem: $ROOT" >&2; exit 2; }

# Keep repeated builds deterministic without depending on any developer account.
rm -f "$ROOT/etc/sudoers.d/atlantian-deploy"

# An empty hash is intentional for first provisioning and is allowed by sshd.
# `passwd` later replaces it with a normal hash, which also suppresses the
# interactive warning installed below.
chroot "$ROOT" passwd -d root
chroot "$ROOT" passwd -u root || true

# An optional public deploy key grants key-based root access. No private key or
# other secret material is ever copied into the image.
if [[ -n "$ATLANTIAN_DEPLOY_KEY_FILE" ]]; then
  [[ -r "$ATLANTIAN_DEPLOY_KEY_FILE" ]] || { echo "unreadable deploy key" >&2; exit 2; }
  install -d -m 0700 -o root -g root "$ROOT/root/.ssh"
  install -m 0600 -o root -g root "$ATLANTIAN_DEPLOY_KEY_FILE" "$ROOT/root/.ssh/authorized_keys"
fi

install -d -m 0755 "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/systemd/system/ssh.service.wants"
cat >"$ROOT/etc/ssh/sshd_config.d/10-atlantian-access.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
KbdInteractiveAuthentication no
UsePAM yes
Banner /etc/issue.net
EOF

install -d -m 0755 "$ROOT/usr/lib/systemd/system"
cat >"$ROOT/usr/lib/systemd/system/atlantian-ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Generate unique SSH host keys on first boot
DefaultDependencies=no
Wants=local-fs.target
After=local-fs.target
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes
EOF
ln -sfn /usr/lib/systemd/system/atlantian-ssh-hostkeys.service \
  "$ROOT/etc/systemd/system/ssh.service.wants/atlantian-ssh-hostkeys.service"

# Validate the final sshd configuration without retaining shared host keys.
chroot "$ROOT" /usr/bin/ssh-keygen -A
chroot "$ROOT" /usr/sbin/sshd -t
rm -f "$ROOT"/etc/ssh/ssh_host_*

install -d -m 0755 "$ROOT/etc/profile.d"
cat >"$ROOT/etc/profile.d/00-atlantian-root-password-warning.sh" <<'EOF'
# Only interactive root shells receive this; a non-empty shadow field means
# that the owner has run passwd and the appliance is no longer wide open.
if [ "$(id -u)" = 0 ] && [ -t 1 ] && [ -z "$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)" ]; then
  printf '\n*** SECURITY WARNING: root has no password. Run: passwd ***\n\n'
fi
EOF

echo "Provisioned root-only SSH access in $ROOT"
