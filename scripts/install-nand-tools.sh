#!/usr/bin/env bash
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${1:?usage: install-nand-tools.sh ROOTFS EDITION}
EDITION=${2:?usage: install-nand-tools.sh ROOTFS EDITION}
[[ -d $ROOT ]] || { echo "missing rootfs: $ROOT" >&2; exit 2; }
case "$EDITION" in sd|nand|nand-installer) ;; *) echo "invalid storage edition: $EDITION" >&2; exit 64 ;; esac

install -D -m 0755 "$PROJECT/scripts/atlantian-nand-backup.sh" "$ROOT/usr/local/sbin/atlantian-nand-backup"
# Stable user-facing launchers sit in front of the install/upgrade cores. They
# ensure an embedded NAND payload is used only when its release identity matches
# the running system or an explicitly prepared maintenance transaction.
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-install.sh" "$ROOT/usr/local/sbin/atlantian-nand-install-core"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-install-launcher.sh" "$ROOT/usr/local/sbin/atlantian-nand-install"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-upgrade.sh" "$ROOT/usr/local/sbin/atlantian-nand-upgrade-core"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-upgrade-launcher.sh" "$ROOT/usr/local/sbin/atlantian-nand-upgrade"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-rebase.sh" "$ROOT/usr/local/sbin/atlantian-nand-rebase"
install -D -m 0755 "$PROJECT/scripts/atlantian-storage.sh" "$ROOT/usr/local/sbin/atlantian-storage"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-firstboot.sh" "$ROOT/usr/local/sbin/atlantian-nand-firstboot"
install -D -m 0755 "$PROJECT/scripts/atlantian-nand-reconcile.sh" "$ROOT/usr/local/sbin/atlantian-nand-reconcile"
install -D -m 0644 "$PROJECT/systemd/atlantian-nand-auto-resume.service" \
  "$ROOT/usr/lib/systemd/system/atlantian-nand-auto-resume.service"
install -D -m 0644 "$PROJECT/systemd/atlantian-nand-reconcile.service" \
  "$ROOT/usr/lib/systemd/system/atlantian-nand-reconcile.service"

# Only an SD boot is allowed to continue a destructive install transaction. The
# unit is inert unless a pending marker exists, so normal SD boots pay no cost.
install -d -m 0755 "$ROOT/etc/systemd/system/multi-user.target.wants"
if [[ $EDITION == sd || $EDITION == nand-installer ]]; then
  ln -sfn /usr/lib/systemd/system/atlantian-nand-auto-resume.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/atlantian-nand-auto-resume.service"
else
  rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/atlantian-nand-auto-resume.service"
fi

# After a full NAND base replacement a freshly rebased upper can carry package
# intent. Reconciliation is one-shot for whichever upper (internal/external) is
# active on that boot.
if [[ $EDITION == nand ]]; then
  ln -sfn /usr/lib/systemd/system/atlantian-nand-reconcile.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/atlantian-nand-reconcile.service"
else
  rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/atlantian-nand-reconcile.service"
fi

# A live NAND base cannot safely consume the SD-oriented three-.deb updater.
# Only the ordinary SD product keeps the live three-.deb sysupgrade path.
if [[ $EDITION == nand || $EDITION == nand-installer ]]; then
  install -D -m 0755 "$PROJECT/scripts/atlantian-sysupgrade-nand.sh" "$ROOT/usr/local/sbin/atlantian-sysupgrade"
fi

install -d -m 0755 "$ROOT/usr/lib/atlantian" "$ROOT/etc/profile.d"
printf '%s\n' "$EDITION" >"$ROOT/usr/lib/atlantian/storage-edition"
cat >"$ROOT/etc/profile.d/20-atlantian-nand-firstboot.sh" <<'EOF_PROFILE'
if [ -x /usr/local/sbin/atlantian-nand-firstboot ]; then
    /usr/local/sbin/atlantian-nand-firstboot
fi
EOF_PROFILE
chmod 0644 "$ROOT/etc/profile.d/20-atlantian-nand-firstboot.sh"
