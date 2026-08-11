#!/bin/sh
# Dynamic post-authentication half of the SSH banner.
set -eu

release=$(cat /usr/lib/atlantian/version 2>/dev/null || printf unknown)
debian_major=$(cat /usr/lib/atlantian/debian-major 2>/dev/null || printf unknown)
debian_codename=$(cat /usr/lib/atlantian/debian-codename 2>/dev/null || printf unknown)
snapshot=$(cat /usr/lib/atlantian/debian-snapshot 2>/dev/null || printf unknown)
kernel=$(uname -r 2>/dev/null || printf unknown)
uptime=$(awk '{ s=int($1); d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); if (d) printf "%dd %dh %dm",d,h,m; else if (h) printf "%dh %dm",h,m; else printf "%dm",m }' /proc/uptime)
previous=$(last -F -w -n 2 root 2>/dev/null | awk 'NR==2 && $1=="root" { $1=""; sub(/^ /,""); print; exit }')
[ -n "$previous" ] || previous=never

printf '\nAtlANTian GNU/Linux %s\n' "$release"
printf 'Debian base: %s (%s)\n' "$debian_major" "$debian_codename"
printf 'Debian snapshot: %s\nKernel: %s\n\n' "$snapshot" "$kernel"
printf 'Hostname: %s\nUptime: %s\nLast login: %s\n\n' "$(hostname)" "$uptime" "$previous"

# Storage UX stays informational here; destructive actions remain explicit tools.
if [ -r /run/atlantian/storage-edition ] && [ "$(cat /run/atlantian/storage-edition)" = nand ]; then
  overlay=$(cat /run/atlantian/overlay-mode 2>/dev/null || printf unknown)
  printf 'Storage: NAND (writable layer: %s)\n' "$overlay"
  if [ -e /var/lib/atlantian/nand/offer-extroot ] \
     && /usr/local/sbin/atlantian-storage is-installer-card >/dev/null 2>&1; then
    printf 'microSD recovery card detected. To use its free ROOT space as the external writable layer without erasing the recovery system:\n'
    printf '  atlantian-storage adopt\n'
  elif [ "$overlay" = internal ]; then
    printf 'No adopted microSD is active; writes are using the internal NAND overlay.\n'
  fi
  printf '\n'
else
  if [ -s /var/lib/atlantian/nand-install/pending ]; then
    printf 'NAND install: continuation is pending/automatic. Check: systemctl status atlantian-nand-auto-resume\n\n'
  elif [ -s /var/lib/atlantian/nand-install/ready-to-handoff ]; then
    printf 'NAND install: verified and ready for boot-source handoff. Run: atlantian-nand-install --handoff\n\n'
  fi
fi

pending=/var/lib/atlantian/update/major-upgrade-pending.env
backup_marker=/var/lib/atlantian/update/major-upgrade-sources-backup
if [ -s "$pending" ]; then
  target=$(sed -n 's/^target_version=//p' "$pending" | head -n1)
  printf 'UPDATE WARNING: Debian major upgrade to %s is incomplete.\n' "${target:-unknown}"
  printf 'Run: atlantian-sysupgrade\n\n'
elif [ -n "${SSH_CONNECTION:-}" ]; then
  /usr/local/sbin/atlantian-release-check --notice || true
fi
if [ -s "$backup_marker" ]; then
  printf 'APT note: third-party sources from the last Debian major upgrade are disabled.\n'
  printf 'Review backup: %s\n\n' "$(cat "$backup_marker")"
fi
