#!/usr/bin/env bash
# Fast contracts for public release naming, compression, asset ordering and
# download metrics. CI must never inflate the user-facing counters.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { printf 'RELEASE METRICS CONTRACT FAILED: %s\n' "$*" >&2; exit 1; }
require() {
  local pattern=$1 file=$2
  grep -Fq -- "$pattern" "$file" || fail "$file is missing: $pattern"
}
reject() {
  local pattern=$1 file=$2
  if grep -Fq -- "$pattern" "$file"; then
    fail "$file still contains forbidden text: $pattern"
  fi
}
line_in_block() {
  local pattern=$1 block=$2
  grep -nF -- "$pattern" "$block" | head -n1 | cut -d: -f1
}

workflow=.github/workflows/build-release.yml
metrics=.github/workflows/image-download-metrics.yml
build=scripts/build-incremental.sh
artifacts=scripts/test-release-artifacts.sh
upgrade=scripts/test-release-upgrade.sh
checker=scripts/atlantian-release-check.sh
sd=scripts/atlantian-sysupgrade.sh
nand=scripts/atlantian-sysupgrade-nand.sh
notes=scripts/generate-release-notes.sh
pipeline=docs/PIPELINE.md
readme=README.md
quickstart=docs/QUICKSTART.md
installation=docs/INSTALLATION.md

# The canonical image name is versioned by config/release.env. CI must not
# override it with a stable filename. The public artifact is XZ-compressed;
# the raw image remains private in the sealed Actions artifact for validation.
reject 'ATLANTIAN_IMAGE_NAME=atlantian' "$workflow"
require 'test "$ATLANTIAN_IMAGE_NAME" = "$ATLANTIAN_RELEASE_ID"' "$workflow"
require 'artifacts/current/*.img.xz' "$workflow"
require '"artifacts/current/$ATLANTIAN_IMAGE_NAME.img.xz"' "$workflow"
require 'COMPRESSED_IMAGE=${COMPRESSED_IMAGE:-$SD_IMAGE.xz}' "$build"
require 'xz -T0 -6 --check=crc64 -c "$SD_IMAGE"' "$build"
require 'xz -t "$COMPRESSED_IMAGE.tmp"' "$build"
require 'decoded_sha=$(xz -dc "$COMPRESSED_IMAGE" | sha256sum' "$build"
require 'sha256sum *.img *.tar.zst *.deb RELEASE-METADATA.json' "$build"
require 'sha256sum *.img.xz >>SHA256SUMS' "$build"
require 'compressed image does not round-trip to the verified raw image' "$artifacts"
require 'retention-days: 90' "$workflow"

# Release upload order is explicit: versioned image first, installed-system
# update payloads second, JSON assets third, checksums last. The chosen names
# also preserve this order in GitHub's current natural asset listing.
block=$(mktemp)
trap 'rm -f "$block"' EXIT
awk '/release_assets=\(/ {capture=1} capture {print} capture && /^[[:space:]]*\)[[:space:]]*$/ {exit}' "$workflow" >"$block"
for item in \
  '"artifacts/current/$ATLANTIAN_IMAGE_NAME.img.xz"' \
  'artifacts/current/atlantian-kernel_*.deb' \
  '"artifacts/current/atlantian-nand-$ATLANTIAN_VERSION.tar.zst"' \
  'artifacts/current/atlantian-platform_*.deb' \
  'artifacts/current/atlantian-release_*.deb' \
  'artifacts/current/atlantian-update.json' \
  'artifacts/current/RELEASE-METADATA.json' \
  'artifacts/current/SHA256SUMS'; do
  require "$item" "$block"
done
prev=0
for item in \
  '"artifacts/current/$ATLANTIAN_IMAGE_NAME.img.xz"' \
  'artifacts/current/atlantian-kernel_*.deb' \
  '"artifacts/current/atlantian-nand-$ATLANTIAN_VERSION.tar.zst"' \
  'artifacts/current/atlantian-platform_*.deb' \
  'artifacts/current/atlantian-release_*.deb' \
  'artifacts/current/atlantian-update.json' \
  'artifacts/current/RELEASE-METADATA.json' \
  'artifacts/current/SHA256SUMS'; do
  line=$(line_in_block "$item" "$block")
  [[ -n $line && $line -gt $prev ]] || fail "release asset order is invalid at: $item"
  prev=$line
done
if grep -Eq '\$ATLANTIAN_IMAGE_NAME\.img"' "$block"; then
  fail 'raw .img must remain private and must not be uploaded to GitHub Releases'
fi

# The integration upgrade gate consumes the private Actions artifact rather than
# public Release download URLs, otherwise CI pollutes user-facing counters.
require 'gh run download "$SOURCE_RUN_ID"' "$upgrade"
require 'atlantian-verified-${source_sha}' "$upgrade"
if grep -Fq 'browser_download_url' "$upgrade"; then
  fail 'release-upgrade gate still resolves public Release asset download URLs'
fi

# Runtime update accounting is deliberately anonymous and best-effort.
require 'atlantian-update.json' "$checker"
require 'record_update_download' "$sd"
require 'record_update_download' "$nand"
require 'blackf1re.github.io%2Fatlantian%2Fimage-downloads.json' "$readme"
require 'query=%24.imageDownloads&label=image%20downloads' "$readme"
require 'query=%24.systemUpdates&label=system%20updates' "$readme"
reject 'github/downloads/BlackF1re/atlantian/total' "$readme"
reject '/atlantian-update.json.svg' "$readme"
require 'atlantian-<release>.img.xz' "$readme"
require 'atlantian-<release>.img.xz' "$quickstart"
require 'atlantian-<release>.img.xz' "$installation"

# Per-asset counters are published once through Pages and then consumed by
# dynamic badges in every Artifacts table. Historical release notes are
# rewritten idempotently only when their table differs from the canonical form.
require 'contents: write' "$metrics"
require 'workflow_run:' "$metrics"
require 'workflows: [Build & Release]' "$metrics"
require 'types: [completed]' "$metrics"
require 'Decide metrics refresh' "$metrics"
# workflow_run refreshes must be tied to the exact release source SHA. Check the
# data flow rather than a single jq spelling so harmless implementation changes
# do not invalidate the contract while SHA matching remains mandatory.
require 'WORKFLOW_HEAD_SHA: ${{ github.event.workflow_run.head_sha }}' "$metrics"
require '--arg sha "$WORKFLOW_HEAD_SHA"' "$metrics"
require '.target_commitish == $sha' "$metrics"
require 'needs.gate.outputs.refresh == '"'"'true'"'"'' "$metrics"
require '"schemaVersion": 3' "$metrics"
require '.schemaVersion == 3' "$metrics"
require '"assetDownloads"' "$metrics"
require '"assetIndex"' "$metrics"
require 'hashlib.sha256(f"{tag}\n{name}".encode()).hexdigest()' "$metrics"
require 'Backfill artifact download columns' "$metrics"
require 'gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id"' "$metrics"
require '| Artifact | Size | Downloads |' "$notes"
require '$.assetDownloads.' "$notes"
require 'prefix": "↓ "' "$notes"
require 'cacheSeconds": "3600"' "$notes"
require 'per-asset' "$pipeline"
require 'Downloads' "$pipeline"

# Sanity-check the filename order we depend on for the Releases UI.
mapfile -t names < <(printf '%s\n' \
  'atlantian-13.1.0-alpha.6.img.xz' \
  'atlantian-kernel_13.1.0.alpha.6-1_armhf.deb' \
  'atlantian-nand-13.1.0-alpha.6.tar.zst' \
  'atlantian-platform_13.1.0.alpha.6-1_all.deb' \
  'atlantian-release_13.1.0.alpha.6-1_all.deb' \
  'atlantian-update.json' \
  'RELEASE-METADATA.json' \
  'SHA256SUMS' | LC_ALL=C sort -f)
[[ ${names[0]} == atlantian-13.1.0-alpha.6.img.xz ]] || fail 'versioned image no longer sorts first'
[[ ${names[5]} == atlantian-update.json ]] || fail 'update marker no longer follows update payloads'
[[ ${names[6]} == RELEASE-METADATA.json && ${names[7]} == SHA256SUMS ]] || fail 'metadata/checksum ordering changed'

echo 'versioned XZ image, release ordering, immediate post-release refresh, per-asset download badges, anonymous updater accounting and CI-isolated counters passed'
