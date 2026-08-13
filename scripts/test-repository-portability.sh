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

# Release-state discovery must use the authenticated GitHub API instead of the
# checkout origin. Checkout credentials are deliberately not persisted, and a
# fresh repository may be private.
require 'gh api "repos/$GITHUB_REPOSITORY/commits/$release_tag"' "$workflow"
require 'gh api "repos/$GITHUB_REPOSITORY/commits/$RELEASE_TAG"' "$workflow"
require 'gh api "repos/$GITHUB_REPOSITORY/commits/main"' "$workflow"

# The plan job owns idempotency and verified-build reuse. Reuse is scoped to the
# exact source SHA so a publication retry cannot silently consume another build.
require '- name: Find reusable verified build' "$workflow"
require 'artifact_name="atlantian-verified-${GITHUB_SHA}"' "$workflow"
require 'gh api --method GET "repos/$GITHUB_REPOSITORY/actions/artifacts"' "$workflow"
require 'select(.expired == false and .workflow_run.head_sha == env.GITHUB_SHA)' "$workflow"
require 'already_published=true' "$workflow"
require 'build_required=false' "$workflow"
require 'Reusing verified artifact $artifact_name from workflow run $reuse_run_id.' "$workflow"

# Publication is immutable. A stale tag/release owned by another source is a hard
# conflict; the workflow must never recover by retargeting history. A superseded
# main revision also cannot publish.
require '- name: Check publication eligibility' "$workflow"
require 'This build was superseded by a newer main commit; publication is skipped.' "$workflow"
require 'Release $RELEASE_TAG belongs to another source revision' "$workflow"
require 'Tag $RELEASE_TAG already points to $tag_commit; automatic publication will never retarget an existing tag.' "$workflow"
if grep -Fq 'gh api --method PATCH' "$workflow" || grep -Fq -- '-F force=true' "$workflow"; then
  fail 'build-release.yml must not retarget an existing release tag'
fi

# A verified artifact must carry the exact source/version markers and publication
# must re-check them after download before creating the GitHub Release.
require 'gh run download "$source_run"' "$workflow"
require 'test "$(cat artifacts/current/VERIFIED-SOURCE-SHA)" = "$GITHUB_SHA"' "$workflow"
require 'test "$(cat artifacts/current/VERIFIED-VERSION)" = "$ATLANTIAN_VERSION"' "$workflow"
require 'gh release create "$RELEASE_TAG"' "$workflow"
require '--target "$GITHUB_SHA"' "$workflow"
require 'Release $RELEASE_TAG appeared concurrently for this source; treating publication as successful.' "$workflow"

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

echo 'fresh-repository release planning, exact-SHA artifact reuse, immutable publication, archive-safe invocation, Git-origin inference and repository stamping passed'
