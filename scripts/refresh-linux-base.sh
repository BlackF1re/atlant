#!/usr/bin/env bash
# Advance only the configured Linux LTS patch line to its newest stable tag.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT"
. config/release.env

fail() { printf 'Linux refresh: %s\n' "$*" >&2; exit 1; }
emit() {
  printf '%s=%s\n' "$1" "$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi
}

[[ $ATLANTIAN_KERNEL_SERIES =~ ^[0-9]+\.[0-9]+$ ]] || fail 'kernel LTS series must be major.minor'
case "$ATLANTIAN_KERNEL_VERSION" in
  "$ATLANTIAN_KERNEL_SERIES".*) current_patch=${ATLANTIAN_KERNEL_VERSION#"$ATLANTIAN_KERNEL_SERIES".} ;;
  *) fail 'configured kernel version is outside the selected LTS series' ;;
esac
[[ $current_patch =~ ^[0-9]+$ ]] || fail 'configured kernel patchlevel is invalid'
[[ $ATLANTIAN_KERNEL_COMMIT =~ ^[0-9a-f]{40}$ ]] || fail 'configured kernel commit is not immutable'

refs=$(git ls-remote --tags --refs "$ATLANTIAN_KERNEL_REPOSITORY" "refs/tags/v${ATLANTIAN_KERNEL_SERIES}.*") \
  || fail 'cannot enumerate Linux stable tags'
latest_tag=$(KERNEL_REFS="$refs" python3 - "$ATLANTIAN_KERNEL_SERIES" <<'PY'
import os, re, sys
series = sys.argv[1]
best = None
for line in os.environ.get('KERNEL_REFS', '').splitlines():
    parts = line.split()
    if len(parts) != 2:
        continue
    ref = parts[1]
    m = re.fullmatch(rf"refs/tags/v{re.escape(series)}\.(\d+)", ref)
    if not m:
        continue
    patch = int(m.group(1))
    if best is None or patch > best[0]:
        best = (patch, ref.rsplit('/', 1)[1])
if best is None:
    raise SystemExit(1)
print(best[1])
PY
) || fail "no stable v${ATLANTIAN_KERNEL_SERIES}.x tags were found"

candidate_version=${latest_tag#v}
candidate_patch=${candidate_version##*.}
if (( candidate_patch <= current_patch )); then
  emit changed false
  emit version "$ATLANTIAN_KERNEL_VERSION"
  emit commit "$ATLANTIAN_KERNEL_COMMIT"
  exit 0
fi

candidate_commit=$(git ls-remote --tags "$ATLANTIAN_KERNEL_REPOSITORY" "refs/tags/${latest_tag}^{}" | awk 'NR==1 {print $1}')
if [[ -z $candidate_commit ]]; then
  candidate_commit=$(git ls-remote --tags --refs "$ATLANTIAN_KERNEL_REPOSITORY" "refs/tags/$latest_tag" | awk 'NR==1 {print $1}')
fi
[[ $candidate_commit =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve $latest_tag to an immutable commit"

python3 - "$candidate_version" "$candidate_commit" <<'PY'
from pathlib import Path
import re, sys
version, commit = sys.argv[1:]
path = Path('config/release.env')
text = path.read_text()
text, n1 = re.subn(r'^ATLANTIAN_KERNEL_VERSION=.*$', f'ATLANTIAN_KERNEL_VERSION={version}', text, count=1, flags=re.M)
text, n2 = re.subn(r'^ATLANTIAN_KERNEL_COMMIT=.*$', f'ATLANTIAN_KERNEL_COMMIT={commit}', text, count=1, flags=re.M)
if n1 != 1 or n2 != 1:
    raise SystemExit('kernel pin fields are missing or duplicated')
path.write_text(text)
PY

emit changed true
emit version "$candidate_version"
emit commit "$candidate_commit"
echo "Linux LTS candidate: $ATLANTIAN_KERNEL_VERSION -> $candidate_version ($candidate_commit)"
