#!/usr/bin/env bash
# Host-side static contract for the board-specific D3 update indicator and its
# lifecycle inside the package updater.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE=$ROOT/scripts/atlantian-update-leds.sh
UPGRADER=$ROOT/scripts/atlantian-sysupgrade.sh

sh -n "$SOURCE"
sh -n "$UPGRADER"
grep -qx "PATTERN='red red red green green green'" "$SOURCE"
grep -qx 'ON_SECONDS=0.05' "$SOURCE"
grep -qx 'OFF_SECONDS=0.05' "$SOURCE"
grep -Fqx 'trap terminate INT TERM HUP' "$SOURCE"
grep -Fqx 'RESTART_SERVICES=${ATLANTIAN_UPDATE_RESTART_SERVICES:-1}' "$SOURCE"
grep -Fq 'if [ "$RESTART_SERVICES" = 1 ]; then' "$SOURCE"
grep -Fqx 'systemctl stop $SERVICES >/dev/null 2>&1 || true' "$SOURCE"
! grep -qi 'recovery' "$SOURCE"

grep -Fq 'ATLANTIAN_UPDATE_RESTART_SERVICES=0 "$LED_HELPER" &' "$UPGRADER"
grep -Fq 'trap restore_update_leds EXIT' "$UPGRADER"
# These commands live inside reboot_now(), so indentation is implementation
# detail. Match the command text rather than requiring column-zero placement.
grep -Fq 'trap - EXIT INT TERM HUP' "$UPGRADER"
grep -Fq 'wait "$ledpid" || true' "$UPGRADER"
start_line=$(grep -n '^start_update_leds$' "$UPGRADER" | tail -n1 | cut -d: -f1)
download_line=$(grep -n '^download_and_verify$' "$UPGRADER" | tail -n1 | cut -d: -f1)
[[ -n $start_line && -n $download_line && $start_line -lt $download_line ]]

echo 'update LED contract passed'
