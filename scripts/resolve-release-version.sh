#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

unset ATLANTIAN_PATCH_OVERRIDE ATLANTIAN_PRERELEASE_OVERRIDE
. config/release.env

SOURCE_SHA=${1:-${GITHUB_SHA:-HEAD}}
source_commit=$(git rev-parse "${SOURCE_SHA}^{commit}")

if [[ -n "$ATLANTIAN_PRERELEASE" ]]; then
    if [[ ! "$ATLANTIAN_PRERELEASE" =~ ^([0-9A-Za-z-]+)\.([0-9]+)$ ]]; then
        printf 'Automatic prerelease numbering requires <channel>.<number>, got: %s\n' "$ATLANTIAN_PRERELEASE" >&2
        exit 1
    fi

    channel=${BASH_REMATCH[1]}
    configured_seq=${BASH_REMATCH[2]}
    patch=$ATLANTIAN_PATCH
    current_tag=
    max_seq=0

    while IFS= read -r tag; do
        if [[ "$tag" =~ ^v${DEBIAN_MAJOR}\.${ATLANTIAN_MINOR}\.${patch}-${channel}\.([0-9]+)$ ]]; then
            current_tag=$tag
            break
        fi
    done < <(git tag --points-at "$source_commit" --sort=-v:refname)

    if [[ -n "$current_tag" ]]; then
        prerelease=${current_tag#v${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${patch}-}
    else
        while IFS= read -r tag; do
            if [[ "$tag" =~ ^v${DEBIAN_MAJOR}\.${ATLANTIAN_MINOR}\.${patch}-${channel}\.([0-9]+)$ ]]; then
                seq=${BASH_REMATCH[1]}
                (( seq > max_seq )) && max_seq=$seq
            fi
        done < <(git tag --list "v${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${patch}-${channel}.*")

        resolved_seq=$configured_seq
        (( max_seq >= resolved_seq )) && resolved_seq=$((max_seq + 1))
        prerelease="${channel}.${resolved_seq}"
    fi
else
    prerelease=
    current_tag=
    max_patch=-1

    while IFS= read -r tag; do
        if [[ "$tag" =~ ^v${DEBIAN_MAJOR}\.${ATLANTIAN_MINOR}\.([0-9]+)$ ]]; then
            current_tag=$tag
            break
        fi
    done < <(git tag --points-at "$source_commit" --sort=-v:refname)

    if [[ -n "$current_tag" ]]; then
        patch=${current_tag##*.}
    else
        while IFS= read -r tag; do
            if [[ "$tag" =~ ^v${DEBIAN_MAJOR}\.${ATLANTIAN_MINOR}\.([0-9]+)$ ]]; then
                candidate=${BASH_REMATCH[1]}
                (( candidate > max_patch )) && max_patch=$candidate
            fi
        done < <(git tag --list "v${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.*")

        patch=$ATLANTIAN_PATCH
        (( max_patch >= patch )) && patch=$((max_patch + 1))
    fi
fi

if [[ -n "$prerelease" ]]; then
    version="${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${patch}-${prerelease}"
else
    version="${DEBIAN_MAJOR}.${ATLANTIAN_MINOR}.${patch}"
fi

printf 'Resolved AtlANTian release version: %s\n' "$version"

if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        printf 'ATLANTIAN_PATCH_OVERRIDE=%s\n' "$patch"
        printf 'ATLANTIAN_PRERELEASE_OVERRIDE=%s\n' "$prerelease"
    } >> "$GITHUB_ENV"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        printf 'version=%s\n' "$version"
        printf 'patch=%s\n' "$patch"
        printf 'prerelease=%s\n' "$prerelease"
    } >> "$GITHUB_OUTPUT"
fi
