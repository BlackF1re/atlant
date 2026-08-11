#!/usr/bin/env bash
# Embed the release-matched NAND payload into the ordinary SD rootfs. This is
# what makes a single AtlANTian image both the normal SD system and NAND
# installer/recovery medium.
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS=${ROOTFS:-$PROJECT/out/rootfs}
BUNDLE=${BUNDLE:-$PROJECT/out/nand/bundle}

[[ -d $ROOTFS ]] || { echo "SD rootfs missing: $ROOTFS" >&2; exit 2; }
[[ -s $BUNDLE/NAND-MANIFEST.json && -s $BUNDLE/SHA256SUMS ]] || { echo "NAND bundle missing: $BUNDLE" >&2; exit 2; }
(cd "$BUNDLE" && sha256sum -c SHA256SUMS >/dev/null)

sudo rm -rf "$ROOTFS/usr/lib/atlantian/nand"
sudo mkdir -p "$ROOTFS/usr/lib/atlantian/nand"
sudo cp -a "$BUNDLE/." "$ROOTFS/usr/lib/atlantian/nand/"

# Make the embedded copy self-verifying before the image is assembled.
(cd "$ROOTFS/usr/lib/atlantian/nand" && sha256sum -c SHA256SUMS >/dev/null)
echo "Embedded NAND payload into SD rootfs: $ROOTFS/usr/lib/atlantian/nand"
