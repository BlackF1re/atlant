#!/usr/bin/env bash
# Create a short-lived maintenance PR, validate its exact head SHA through the
# required CI workflow, then squash-merge it into protected main. This helper is
# intentionally generic so scheduled maintenance never needs a direct main push.
set -euo pipefail

usage() {
  echo 'usage: merge-protected-main.sh <branch> <title> <base-sha> <head-sha>' >&2
  exit 64
}

[[ $# -eq 4 ]] || usage
BRANCH=$1
TITLE=$2
BASE_SHA=$3
HEAD_SHA=$4
REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}

fail() {
  echo "protected main merge: $*" >&2
  exit 1
}

[[ $BRANCH =~ ^maintenance/[A-Za-z0-9._/-]+$ ]] || fail "unsafe maintenance branch: $BRANCH"
[[ $BASE_SHA =~ ^[0-9a-f]{40}$ ]] || fail "invalid base SHA: $BASE_SHA"
[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || fail "invalid head SHA: $HEAD_SHA"
[[ $(git rev-parse HEAD) == "$HEAD_SHA" ]] || fail 'HEAD does not match requested maintenance head'
[[ $(git rev-parse HEAD^) == "$BASE_SHA" ]] || fail 'maintenance commit is not based on the expected main SHA'

current_main=$(gh api "repos/$REPO/commits/main" --jq .sha)
[[ $current_main == "$BASE_SHA" ]] || fail "main moved before maintenance PR creation: expected $BASE_SHA, got $current_main"

pr=
merged=false
cleanup() {
  set +e
  if [[ $merged != true && -n ${pr:-} ]]; then
    gh api --method PATCH "repos/$REPO/pulls/$pr" -f state=closed >/dev/null 2>&1 || true
  fi
  gh api --method DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The temporary branch is intentionally outside protected main. The only route
# into main below is the GitHub pull-request merge API after exact-SHA CI passes.
git push origin "HEAD:refs/heads/$BRANCH" >&2

pr=$(gh api --method POST "repos/$REPO/pulls" \
  -f title="$TITLE" \
  -f head="$BRANCH" \
  -f base=main \
  -f body='Automated AtlANTian maintenance change. The exact head SHA is explicitly validated before protected-main squash merge.' \
  --jq .number)
echo "Created maintenance PR #$pr for $HEAD_SHA." >&2

# Events produced with GITHUB_TOKEN do not recursively trigger pull_request
# workflows, so dispatch CI explicitly on the exact PR branch and SHA.
gh workflow run ci.yml --repo "$REPO" --ref "$BRANCH" \
  -f base_sha="$BASE_SHA" \
  -f head_sha="$HEAD_SHA"

run_id=
for _ in $(seq 1 30); do
  run_id=$(gh run list --repo "$REPO" --workflow ci.yml --branch "$BRANCH" \
    --event workflow_dispatch --limit 20 \
    --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$HEAD_SHA\") | .databaseId" | head -n1)
  [[ -n $run_id ]] && break
  sleep 2
done
[[ -n $run_id ]] || fail 'explicit Validate workflow run did not appear'

echo "Waiting for Validate workflow run $run_id." >&2
gh run watch "$run_id" --repo "$REPO" --exit-status --interval 2 >&2

current_main=$(gh api "repos/$REPO/commits/main" --jq .sha)
[[ $current_main == "$BASE_SHA" ]] || fail "main moved during validation: expected $BASE_SHA, got $current_main"

merge_json=$(mktemp)
trap 'rm -f "$merge_json"; cleanup' EXIT
if ! gh api --method PUT "repos/$REPO/pulls/$pr/merge" \
  -f merge_method=squash \
  -f sha="$HEAD_SHA" \
  -f commit_title="$TITLE" >"$merge_json"; then
  fail 'GitHub rejected the protected-main squash merge'
fi
[[ $(jq -r '.merged' "$merge_json") == true ]] || {
  jq . "$merge_json" >&2
  fail 'maintenance PR was not merged'
}
merge_sha=$(jq -r '.sha' "$merge_json")
[[ $merge_sha =~ ^[0-9a-f]{40}$ ]] || fail 'merge response has no valid commit SHA'

current_main=$(gh api "repos/$REPO/commits/main" --jq .sha)
[[ $current_main == "$merge_sha" ]] || fail "protected main tip does not match merge result: $current_main != $merge_sha"

merged=true
gh api --method DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
rm -f "$merge_json"
trap - EXIT
printf '%s\n' "$merge_sha"
