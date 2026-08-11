#!/usr/bin/env bash
# Upstream modules_install leaves ELF debug/symbol sections that are useful to a
# kernel developer but waste persistent storage on both AtlANTian editions.
set -euo pipefail
ROOT=${1:?usage: strip-kernel-modules.sh ROOTFS}
STRIP=${CROSS_COMPILE:-arm-linux-gnueabihf-}strip
command -v "$STRIP" >/dev/null || { echo "missing $STRIP" >&2; exit 69; }
[[ -d $ROOT/lib/modules ]] || { echo "missing modules tree: $ROOT/lib/modules" >&2; exit 2; }
mapfile -d '' modules < <(find "$ROOT/lib/modules" -type f -name '*.ko' -print0)
((${#modules[@]})) || exit 0
"$STRIP" --strip-debug "${modules[@]}"
