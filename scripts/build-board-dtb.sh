#!/usr/bin/env bash
# Build the board DTB from the exact Linux source pinned for this release.
set -euo pipefail

PROJECT=$(cd "$(dirname "$0")/.." && pwd)
exec bash "$PROJECT/scripts/build-kernel.sh" dtb
