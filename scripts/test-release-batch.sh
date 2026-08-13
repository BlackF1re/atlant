#!/usr/bin/env bash
# Exercise automatic release batching, including a brand-new repository.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/scripts/release-batch-state.sh"
fail() { printf 'release batch contract: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/board"
cp "$SCRIPT" "$tmp/scripts/release-batch-state.sh"
printf 'initial\n' >"$tmp/board/state"
git -C "$tmp" init -q
git -C "$tmp" config user.name test
git -C "$tmp" config user.email test@example.invalid
git -C "$tmp" add .
git -C "$tmp" commit -qm initial

bootstrap=$(bash "$tmp/scripts/release-batch-state.sh")
[[ $bootstrap == 5 ]] || fail "fresh repository did not bootstrap immediately: $bootstrap"

git -C "$tmp" tag v13.1.0-alpha.1
for n in 1 2 3 4; do
  printf '%s\n' "$n" >>"$tmp/board/state"
  git -C "$tmp" add board/state
  git -C "$tmp" commit -qm "change $n"
  count=$(bash "$tmp/scripts/release-batch-state.sh")
  [[ $count == "$n" ]] || fail "expected $n qualifying commits, got $count"
done
printf '5\n' >>"$tmp/board/state"
git -C "$tmp" add board/state
git -C "$tmp" commit -qm 'change 5'
[[ $(bash "$tmp/scripts/release-batch-state.sh") == 5 ]] || fail 'fifth qualifying commit did not reach the publication threshold'

# Release-note presentation changes are deliberately excluded from batching.
printf '# presentation only\n' >>"$tmp/scripts/generate-release-notes.sh"
git -C "$tmp" add scripts/generate-release-notes.sh
git -C "$tmp" commit -qm 'notes only'
[[ $(bash "$tmp/scripts/release-batch-state.sh") == 5 ]] || fail 'release-note-only change altered the qualifying commit count'

echo 'fresh-repository bootstrap and five-commit release batching contracts passed'
