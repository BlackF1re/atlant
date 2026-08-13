#!/usr/bin/env bash
# Fast contracts for public release metrics. These checks ensure GitHub Release
# download counters represent user-facing image downloads and update activity,
# never CI fixture traffic.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { printf 'RELEASE METRICS CONTRACT FAILED: %s\n' "$*" >&2; exit 1; }
require() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || fail "$file is missing: $pattern"
}

workflow=.github/workflows/build-release.yml
upgrade=scripts/test-release-upgrade.sh
checker=scripts/atlantian-release-check.sh
sd=scripts/atlantian-sysupgrade.sh
nand=scripts/atlantian-sysupgrade-nand.sh
readme=README.md

# Production releases use a stable image filename. The semantic version remains
# in the tag and metadata, while Shields can sum the same asset across releases.
require 'echo "ATLANTIAN_IMAGE_NAME=atlantian" >> "$GITHUB_ENV"' "$workflow"
require 'retention-days: 90' "$workflow"
require 'artifacts/current/atlantian-update.json' "$workflow"

# The integration upgrade gate must consume the private Actions artifact rather
# than public Release download URLs, otherwise CI pollutes user-facing counters.
require 'gh run download "$SOURCE_RUN_ID"' "$upgrade"
require 'atlantian-verified-${source_sha}' "$upgrade"
if grep -Fq 'browser_download_url' "$upgrade"; then
  fail 'release-upgrade gate still resolves public Release asset download URLs'
fi

# Runtime update accounting is deliberately anonymous and best-effort: the
# stable marker is downloaded only from the real SD/NAND update transaction.
require 'atlantian-update.json' "$checker"
require 'record_update_download' "$sd"
require 'record_update_download' "$nand"
require '/atlantian.img?label=image%20downloads' "$readme"
require '/atlantian-update.json?label=system%20updates' "$readme"

echo 'stable image/update assets, anonymous updater accounting and CI-isolated counters passed'
