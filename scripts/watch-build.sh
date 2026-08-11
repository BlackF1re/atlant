#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG=${ATLANTIAN_LOG_FILE:-$ROOT/logs/rootfs-build.log}
clear
printf 'AtlANTian build monitor\n'
printf 'Log: %s\n\n' "$LOG"
[ -e "$LOG" ] || { echo 'Log does not exist yet; waiting for it to appear.'; mkdir -p "$(dirname "$LOG")"; touch "$LOG"; }
tail -n 80 -F "$LOG"
