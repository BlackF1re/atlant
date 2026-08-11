#!/usr/bin/env bash
# Guard the exact migration model used for AtlANTian releases: export the source
# tree, commit it into a fresh GitHub repository, and let the same workflows build
# and publish without inheriting or depending on state from the previous repo.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { printf 'repository portability contract: %s\n' "$*" >&2; exit 1; }
require() {
  local needle=$1 file=$2
  grep -Fq -- "$needle" "$file" || fail "$file is missing: $needle"
}

workflow=.github/workflows/build-release.yml

# The build must stamp and package the repository in which Actions is actually
# running, not a historical owner/name baked into the source archive.
require 'ATLANTIAN_GITHUB_REPO: ${{ github.repository }}' "$workflow"
require 'ATLANTIAN_RELEASE_REPOSITORY="$ATLANTIAN_GITHUB_REPO"' scripts/stamp-release.sh
require 'HOME_URL="$ATLANTIAN_REPO_URL"' scripts/stamp-release.sh
require 'GITHUB_REPOSITORY' config/atlantian-releases.conf
require 'git config --get remote.origin.url' config/atlantian-releases.conf
require 'Homepage: https://github.com/$RELEASE_REPOSITORY' scripts/build-atlantian-debs.sh
require 'debian-snapshot release-repo os-release runtime-sources.list' scripts/build-atlantian-debs.sh
require 'GITHUB_REPOSITORY' scripts/test-release-upgrade.sh

# A downloaded/re-uploaded source archive may lose executable mode bits. Actions
# and nested build helpers must use explicit interpreters instead of depending on
# Git mode 100755 surviving the migration.
require 'sudo -E bash ./scripts/build-incremental.sh rootfs' "$workflow"
require 'sudo -E bash ./scripts/build-incremental.sh kernel' "$workflow"
require 'sudo -E bash ./scripts/build-incremental.sh artifacts' "$workflow"
require 'bash "$ROOT/scripts/populate-boot-files.sh"' scripts/build-atlantian-debs.sh
if grep -Eq '^[[:space:]]*(run:[[:space:]]*)?(sudo[[:space:]]+-E[[:space:]]+)?\./scripts/[A-Za-z0-9_.-]+\.sh([[:space:]]|$)' "$workflow"; then
  fail 'build-release.yml contains a direct repository-script execution that depends on executable mode bits'
fi

# Release-state reads must use the authenticated API instead of the checkout's
# origin. Checkout credentials are deliberately not persisted, and a fresh
# repository may be private.
require 'gh api "repos/$GITHUB_REPOSITORY/commits/$RELEASE_TAG"' "$workflow"
require 'gh api "repos/$GITHUB_REPOSITORY/commits/main"' "$workflow"

# Discovery of pre-existing GitHub state is diagnostic. A stale tag or an
# already-published release must never make the build fail before validation.
state_block=$(awk '
  /- name: Check release state/ { in_block=1 }
  /- name: Validate source contracts/ { in_block=0 }
  in_block { print }
' "$workflow")
[[ -n $state_block ]] || fail 'cannot locate Check release state block'
if grep -Fq 'exit 1' <<<"$state_block"; then
  fail 'Check release state must not fail merely because a tag or Release already exists'
fi
if grep -Eq 'git[[:space:]]+(ls-remote|fetch)' <<<"$state_block"; then
  fail 'Check release state must not require persisted Git credentials'
fi
grep -Fq 'published-current' <<<"$state_block" || fail 'missing published-current idempotent state'
grep -Fq 'published-other' <<<"$state_block" || fail 'missing published-other immutable state'
grep -Fq 'tag-other' <<<"$state_block" || fail 'missing orphan-tag recovery state'

# A same-source partial publication is recoverable and an unattached stale tag
# is repaired only at the final publication boundary.
require 'gh release upload "$RELEASE_TAG"' "$workflow"
require '--clobber' "$workflow"
require 'gh api --method PATCH' "$workflow"
require '-F force=true' "$workflow"

# Exercise release stamping with an arbitrary GitHub repository identity. This
# catches accidental reintroduction of the historical repository URL.
tmp=$(mktemp -d)
cleanup() {
  sudo rm -rf "$tmp" 2>/dev/null || rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/rootfs/etc"
ATLANTIAN_GITHUB_REPO='fresh-owner/fresh-atlantian' \
ATLANTIAN_SOURCE_REVISION='bootstraptest' \
  bash scripts/stamp-release.sh "$tmp/rootfs"

grep -qx 'fresh-owner/fresh-atlantian' "$tmp/rootfs/usr/lib/atlantian/release-repo" \
  || fail 'release-repo stamp did not follow the supplied repository identity'
grep -qx 'ATLANTIAN_RELEASE_REPOSITORY="fresh-owner/fresh-atlantian"' "$tmp/rootfs/usr/lib/atlantian/os-release" \
  || fail 'os-release repository identity was not stamped'
grep -qx 'HOME_URL="https://github.com/fresh-owner/fresh-atlantian"' "$tmp/rootfs/usr/lib/atlantian/os-release" \
  || fail 'os-release HOME_URL still depends on the historical repository'
grep -qx 'SUPPORT_URL="https://github.com/fresh-owner/fresh-atlantian/issues"' "$tmp/rootfs/usr/lib/atlantian/os-release" \
  || fail 'os-release SUPPORT_URL still depends on the historical repository'

# A manually built source archive that was committed to a new repository must
# infer that new repository from its Git origin even outside GitHub Actions.
mkdir -p "$tmp/fresh-repo"
git -C "$tmp/fresh-repo" init -q
git -C "$tmp/fresh-repo" remote add origin git@github.com:archive-owner/archive-atlantian.git
inferred=$(
  cd "$tmp/fresh-repo"
  unset ATLANTIAN_GITHUB_REPO GITHUB_REPOSITORY
  . "$ROOT/config/atlantian-releases.conf"
  printf '%s\n' "$ATLANTIAN_GITHUB_REPO"
)
[[ $inferred == 'archive-owner/archive-atlantian' ]] \
  || fail "fresh Git origin was not inferred as release repository: $inferred"

# The runtime release client must respect an explicit mirror/fork override.
ATLANTIAN_GITHUB_REPO='another-owner/another-repo'
. config/atlantian-releases.conf
[[ $ATLANTIAN_GITHUB_REPO == 'another-owner/another-repo' ]] \
  || fail 'runtime release configuration overwrote an explicit repository identity'

echo 'fresh-repository release discovery, archive-safe invocation/package construction, private-repo API access, Git-origin inference, publication recovery and repository stamping passed'
