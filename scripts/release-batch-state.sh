#!/usr/bin/env bash
# Report how many release-input commits have accumulated since the last release.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

SOURCE_SHA=${1:-HEAD}
source_commit=$(git rev-parse "${SOURCE_SHA}^{commit}")
last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$source_commit" 2>/dev/null || true)

paths=(
  board
  config
  debian-release.sha256
  debian-security-release.sha256
  debian-updates-release.sha256
  fpga
  kernel-overlay
  scripts
  systemd
  ':(exclude)scripts/generate-release-notes.sh'
)

if [[ -n "$last_tag" ]]; then
  count=$(git rev-list --count "${last_tag}..${source_commit}" -- "${paths[@]}")
else
  count=$(git rev-list --count "$source_commit" -- "${paths[@]}")
fi

printf '%s\n' "$count"
