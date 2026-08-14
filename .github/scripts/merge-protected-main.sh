#!/usr/bin/env bash
# Create a short-lived maintenance PR, validate the exact GitHub-generated
# merge candidate through the required CI workflow, then squash-merge it into
# protected main. Scheduled maintenance therefore never needs a direct main push
# and strict/up-to-date branch protection remains fully enforced.
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
VALIDATION_BRANCH="maintenance-validation/${BRANCH#maintenance/}"

fail() {
  echo "protected main merge: $*" >&2
  exit 1
}

[[ $BRANCH =~ ^maintenance/[A-Za-z0-9._/-]+$ ]] || fail "unsafe maintenance branch: $BRANCH"
[[ $VALIDATION_BRANCH =~ ^maintenance-validation/[A-Za-z0-9._/-]+$ ]] || fail "unsafe validation branch: $VALIDATION_BRANCH"
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
  gh api --method DELETE "repos/$REPO/git/refs/heads/$VALIDATION_BRANCH" >/dev/null 2>&1 || true
  gh api --method DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The maintenance branch is intentionally outside protected main. The only
# route into main below is the GitHub pull-request merge API after CI succeeds
# on the exact merge candidate that strict branch protection evaluates.
git push origin "HEAD:refs/heads/$BRANCH" >&2

pr=$(gh api --method POST "repos/$REPO/pulls" \
  -f title="$TITLE" \
  -f head="$BRANCH" \
  -f base=main \
  -f body='Automated AtlANTian maintenance change. GitHub-generated merge candidate is explicitly validated before protected-main squash merge.' \
  --jq .number)
echo "Created maintenance PR #$pr for $HEAD_SHA." >&2

# With strict/up-to-date branch protection GitHub requires the required check on
# the synthetic merge candidate, not only on the PR head. Wait until GitHub has
# produced that candidate, expose the exact commit temporarily as a branch and
# dispatch CI on that immutable SHA.
MERGE_SHA=
for _ in $(seq 1 30); do
  meta=$(gh api "repos/$REPO/pulls/$pr")
  current_head=$(jq -r '.head.sha // empty' <<<"$meta")
  candidate=$(jq -r '.merge_commit_sha // empty' <<<"$meta")
  mergeable=$(jq -r '.mergeable // empty' <<<"$meta")
  [[ $current_head == "$HEAD_SHA" ]] || fail "maintenance PR head moved before validation: expected $HEAD_SHA, got $current_head"
  if [[ $candidate =~ ^[0-9a-f]{40}$ && $mergeable == true ]]; then
    MERGE_SHA=$candidate
    break
  fi
  [[ $mergeable != false ]] || fail 'maintenance PR is not mergeable'
  sleep 2
done
[[ $MERGE_SHA =~ ^[0-9a-f]{40}$ ]] || fail 'GitHub did not produce a merge candidate for the maintenance PR'

gh api --method POST "repos/$REPO/git/refs" \
  -f ref="refs/heads/$VALIDATION_BRANCH" \
  -f sha="$MERGE_SHA" >/dev/null

echo "Validating GitHub merge candidate $MERGE_SHA for PR #$pr." >&2
# Keep stdout reserved for the single merge SHA returned to the caller. gh may
# print a workflow-dispatch acknowledgement, so route it to the human log.
gh workflow run ci.yml --repo "$REPO" --ref "$VALIDATION_BRANCH" \
  -f base_sha="$BASE_SHA" \
  -f head_sha="$MERGE_SHA" >&2

run_id=
for _ in $(seq 1 30); do
  run_id=$(gh run list --repo "$REPO" --workflow ci.yml --branch "$VALIDATION_BRANCH" \
    --event workflow_dispatch --limit 20 \
    --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$MERGE_SHA\") | .databaseId" | head -n1)
  [[ -n $run_id ]] && break
  sleep 2
done
[[ -n $run_id ]] || fail 'explicit merge-candidate Validate workflow run did not appear'

echo "Waiting for Validate workflow run $run_id." >&2
gh run watch "$run_id" --repo "$REPO" --exit-status --interval 2 >&2

current_main=$(gh api "repos/$REPO/commits/main" --jq .sha)
[[ $current_main == "$BASE_SHA" ]] || fail "main moved during validation: expected $BASE_SHA, got $current_main"
meta=$(gh api "repos/$REPO/pulls/$pr")
current_head=$(jq -r '.head.sha // empty' <<<"$meta")
current_merge=$(jq -r '.merge_commit_sha // empty' <<<"$meta")
[[ $current_head == "$HEAD_SHA" ]] || fail "maintenance PR head moved after validation: expected $HEAD_SHA, got $current_head"
[[ $current_merge == "$MERGE_SHA" ]] || fail "merge candidate changed after validation: expected $MERGE_SHA, got $current_merge"

# Pull requests created with GITHUB_TOKEN do not recursively emit a normal
# pull_request workflow check. Publish a commit-status bridge only after the
# real merge-candidate CI has succeeded. Required-status protection accepts
# commit statuses as well as checks; the status therefore records, rather than
# bypasses, the exact validation result above.
validation_url="https://github.com/$REPO/actions/runs/$run_id"
for sha in "$HEAD_SHA" "$MERGE_SHA"; do
  gh api --method POST "repos/$REPO/statuses/$sha" \
    -f state=success \
    -f context=Validate \
    -f description='Validated by CI on the exact GitHub merge candidate' \
    -f target_url="$validation_url" >/dev/null
done

# Give branch-protection state a short bounded window to observe the successful
# status before the merge API is called.
for _ in $(seq 1 15); do
  state=$(gh api "repos/$REPO/pulls/$pr" --jq '.mergeable_state // empty')
  [[ $state == clean ]] && break
  [[ $state != dirty ]] || fail 'maintenance PR became conflicted after validation'
  sleep 1
done

current_main=$(gh api "repos/$REPO/commits/main" --jq .sha)
[[ $current_main == "$BASE_SHA" ]] || fail "main moved before protected merge: expected $BASE_SHA, got $current_main"
meta=$(gh api "repos/$REPO/pulls/$pr")
current_head=$(jq -r '.head.sha // empty' <<<"$meta")
current_merge=$(jq -r '.merge_commit_sha // empty' <<<"$meta")
[[ $current_head == "$HEAD_SHA" ]] || fail "maintenance PR head moved before protected merge: expected $HEAD_SHA, got $current_head"
[[ $current_merge == "$MERGE_SHA" ]] || fail "merge candidate changed before protected merge: expected $MERGE_SHA, got $current_merge"

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
gh api --method DELETE "repos/$REPO/git/refs/heads/$VALIDATION_BRANCH" >/dev/null 2>&1 || true
gh api --method DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
rm -f "$merge_json"
trap - EXIT
# Machine-readable API for callers: this is the helper's only stdout line.
printf '%s\n' "$merge_sha"
