#!/usr/bin/env bash
# Advance U-Boot only to official stable release tags. RCs and arbitrary branch
# heads are never eligible build inputs; rare stable bugfix tags (YYYY.MM.N) are.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT"
. config/u-boot.env

fail() { printf 'U-Boot refresh: %s\n' "$*" >&2; exit 1; }
emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
}

[[ $ATLANTIAN_UBOOT_VERSION =~ ^([0-9]{4})\.([0-9]{2})(\.([0-9]+))?$ ]] || fail 'configured U-Boot version must be YYYY.MM or YYYY.MM.N'
current_year=${BASH_REMATCH[1]}
current_month=${BASH_REMATCH[2]}
current_patch=${BASH_REMATCH[4]:-0}
(( 10#$current_month >= 1 && 10#$current_month <= 12 )) || fail 'configured U-Boot month is invalid'
[[ $ATLANTIAN_UBOOT_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'configured U-Boot commit is not immutable'

refs=$(git ls-remote --tags --refs "$ATLANTIAN_UBOOT_REPOSITORY" 'refs/tags/v*') \
  || fail 'cannot enumerate U-Boot tags'
latest_tag=$(UBOOT_REFS="$refs" python3 - <<'PY'
import os, re
best = None
for line in os.environ.get('UBOOT_REFS', '').splitlines():
    parts = line.split()
    if len(parts) != 2:
        continue
    ref = parts[1]
    m = re.fullmatch(r'refs/tags/v(\d{4})\.(\d{2})(?:\.(\d+))?', ref)
    if not m:
        continue
    year = int(m.group(1))
    month = int(m.group(2))
    patch = int(m.group(3) or 0)
    if not 1 <= month <= 12:
        continue
    key = (year, month, patch)
    if best is None or key > best[0]:
        best = (key, ref.rsplit('/', 1)[1])
if best is None:
    raise SystemExit(1)
print(best[1])
PY
) || fail 'no stable U-Boot vYYYY.MM[.N] tag was found'

candidate_version=${latest_tag#v}
IFS=. read -r candidate_year candidate_month candidate_patch <<<"$candidate_version"
candidate_patch=${candidate_patch:-0}
if (( 10#$candidate_year < 10#$current_year \
   || (10#$candidate_year == 10#$current_year && 10#$candidate_month < 10#$current_month) \
   || (10#$candidate_year == 10#$current_year && 10#$candidate_month == 10#$current_month && 10#$candidate_patch <= 10#$current_patch) )); then
  emit changed false
  emit version "$ATLANTIAN_UBOOT_VERSION"
  emit commit "$ATLANTIAN_UBOOT_COMMIT"
  exit 0
fi

candidate_commit=$(git ls-remote --tags "$ATLANTIAN_UBOOT_REPOSITORY" "refs/tags/${latest_tag}^{}" | awk 'NR==1 {print $1}')
if [[ -z $candidate_commit ]]; then
  candidate_commit=$(git ls-remote --tags --refs "$ATLANTIAN_UBOOT_REPOSITORY" "refs/tags/$latest_tag" | awk 'NR==1 {print $1}')
fi
[[ $candidate_commit =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve $latest_tag to an immutable commit"

python3 - "$candidate_version" "$candidate_commit" <<'PY'
from pathlib import Path
import re, sys
version, commit = sys.argv[1:]
path = Path('config/u-boot.env')
text = path.read_text()
text, n1 = re.subn(r'^ATLANTIAN_UBOOT_VERSION=.*$', f'ATLANTIAN_UBOOT_VERSION={version}', text, count=1, flags=re.M)
text, n2 = re.subn(r'^ATLANTIAN_UBOOT_COMMIT=.*$', f'ATLANTIAN_UBOOT_COMMIT={commit}', text, count=1, flags=re.M)
if n1 != 1 or n2 != 1:
    raise SystemExit('U-Boot pin fields are missing or duplicated')
path.write_text(text)
PY

emit changed true
emit version "$candidate_version"
emit commit "$candidate_commit"
echo "U-Boot stable candidate: $ATLANTIAN_UBOOT_VERSION -> $candidate_version ($candidate_commit)"
