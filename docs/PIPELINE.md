# Build and release pipeline

This document owns CI/release behavior: triggers, automatic versioning, protected
maintenance merges, verified artifacts, publication and download-metric refreshes.
Debian Snapshot discovery itself is documented in
[Debian lifecycle](DEBIAN-LIFECYCLE.md).

## Production triggers

`Build & Release` can start in these ways:

| Trigger | Build | Publish |
|---|---|---|
| first qualifying push in a repository with no AtlANTian release tag | yes | yes, automatically |
| later push to `main` touching a source/build-input path | after 5 qualifying commits | yes, automatically |
| Debian Watch dispatch (`origin=debian-watch`) | yes | yes, automatically |
| manual `workflow_dispatch`, `publish=false` | yes | no |
| manual `workflow_dispatch`, `publish=true` | yes or reuse | yes |

Automatic push triggers are limited to:

```text
board/**
config/**
debian-*.sha256
fpga/**
kernel-overlay/**
scripts/**
systemd/**
```

Documentation and workflow-only maintenance are excluded from the full release
build path. `scripts/generate-release-notes.sh` is also excluded because it changes
publication presentation rather than image contents.

After the first release, automatic source publication batches five qualifying
commits since the latest version tag. A fresh repository deliberately treats the
no-release state as bootstrap-ready so the first qualifying push publishes a
verified release immediately. Manual `publish=true` and Debian Watch bypass the
five-commit threshold when an immediate release is required.

A newer run on the same ref cancels an older in-progress release run. Publication
also requires the built source SHA to remain the current `main` tip.

## Protected Debian maintenance

Debian Watch never pushes directly to protected `main` and has no protection
bypass. When a Snapshot changes it:

1. creates a short-lived `maintenance/debian-snapshot-*` branch and PR;
2. asks GitHub for the PR's exact synthetic merge candidate;
3. exposes that immutable candidate through a short-lived
   `maintenance-validation/*` branch;
4. explicitly dispatches the normal `CI / Validate` workflow on that exact
   candidate and waits for success;
5. verifies that `main`, the maintenance head and GitHub's merge candidate did not
   move during validation;
6. publishes a `Validate=success` commit status linked to that successful CI run
   so the token-created PR satisfies the repository's required-status interface;
7. squash-merges through GitHub's protected-branch merge API;
8. verifies the resulting `main` SHA and explicitly dispatches `Build & Release`
   with `origin=debian-watch`.

The status bridge records the result of real merge-candidate CI; it is not a
replacement for validation and cannot be written before that CI succeeds. The
explicit dispatches are necessary because events created with the workflow's
`GITHUB_TOKEN` do not recursively create the normal PR/push workflow chain.

The inactivity heartbeat uses the same protected merge path but changes no release
input and never dispatches a release build.

## Automatic release identity

The release line is:

```text
<Debian major>.<AtlANTian minor>.<AtlANTian patch>[-prerelease]
```

Examples:

```text
13.1.0-alpha.N
13.1.0-beta.N
13.1.0-rc.N
13.1.0
13.1.1
```

`config/release.env` defines the Debian generation, AtlANTian minor/initial patch
and prerelease channel. `scripts/resolve-release-version.sh` derives the next
publishable version from repository tags:

- a prerelease channel increments its numeric sequence;
- changing channel starts from that channel's configured sequence;
- a stable line increments the patch when that stable version already exists;
- rerunning an already-tagged source SHA resolves to that existing version rather
  than inventing another one.

Source revision and Debian Snapshot timestamp are metadata, not release-ordering
components. For prereleases, Debian package metadata retains native ordering, for
example `X.Y.Z~alpha.N-1` for release `X.Y.Z-alpha.N`.

A Debian-major transition remains explicit because it changes the release line
itself.

## Plan → build → publish

Production CI is split into separate jobs:

```text
plan
  ↓
build + verify (only when needed)
  ↓
seal SHA-specific verified artifact
  ↓
publish (only when requested and eligible)
```

A successful plan-only run is an orchestration result, not evidence that the
current `main` SHA has a binary image. Published releases are the revisions that
completed the binary build/verification path.

### Plan

The plan job resolves the version and decides whether a build is necessary. For
publication requests it checks:

1. whether the exact version is already published for the exact source SHA;
2. whether a non-expired verified artifact already exists for that source SHA.

A same-version/same-SHA release is an idempotent no-op. A compatible verified
artifact can be reused for publication.

### Build and verify

A required build performs the expensive path:

- source/build contract checks, including release-client/public-filename tests;
- frozen release-input validation;
- Debian rootfs build;
- pinned Linux build;
- SD/NAND U-Boot and NAND payload build;
- unified raw image creation;
- XZ compression plus raw/decompressed SHA-256 equivalence check;
- release artifact validation;
- SD image layout validation;
- NAND artifact validation;
- SD upgrade integration test;
- NAND rebase integration test;
- source-tree integrity check;
- GitHub/Sigstore build provenance attestation.

The raw `atlantian-<release>.img` remains inside the verified Actions artifact so
layout and upgrade gates can use the exact disk image without a public Release
download. The user-facing image is `atlantian-<release>.img.xz`.

The SD upgrade integration test resolves an older published release by tag but
loads its raw image from the matching SHA-sealed Actions artifact. It therefore
does not inflate public image-download counters.

The build records:

```text
VERIFIED-SOURCE-SHA
VERIFIED-VERSION
```

and uploads `atlantian-verified-<full-source-SHA>` with a 90-day maximum retention
period. The sealed artifact contains the raw `.img`, verified `.img.xz`, canonical
Debian `.deb` filenames and its internal checksum manifest. A failed publication
can therefore be retried for the same SHA without rebuilding the OS while that
artifact remains available.

Actions storage is bounded independently of that maximum retention. After a
release is published, `Download Metrics` keeps the newest published release's
SHA-sealed artifact for the next real upgrade test and removes SHA-sealed artifacts
belonging to older published releases. Unpublished verified artifacts are retained
so a failed publication can still be retried without rebuilding. Legacy
version-named build artifacts, which are no longer consumed by the upgrade gate,
are also removed. In steady state the repository therefore retains one large
published build artifact rather than a 90-day history of every release.

### Publish

Publication is allowed only when:

- publication was requested by a qualifying push, Debian Watch or manual
  `publish=true`;
- the build succeeded or a verified same-SHA artifact was reused;
- the workflow source SHA is still current `main`;
- the target tag/release does not belong to another source revision.

Before publication transformation, CI re-verifies the sealed artifact's source
marker, version marker, internal checksum manifest, raw/compressed image pair and
exact three-package `.deb` set.

`prepare-public-release.sh` then transforms only a local publication copy:

1. proves `.img.xz` still decodes to the sealed raw image;
2. keeps Debian package `Version` metadata unchanged;
3. normalizes only public prerelease `.deb` filenames from `~` to `.`;
4. creates deterministic `atlantian-update.json`;
5. writes the public `SHA256SUMS` for exactly the downloadable payload names;
6. lets `generate-release-notes.sh` describe those exact public files.

The raw `.img` remains private to the verified Actions artifact and is not
uploaded to GitHub Releases.

Release assets are uploaded in this logical order:

1. `atlantian-<release>.img.xz`;
2. installed-system update payloads: NAND bundle and three `.deb` packages;
3. `atlantian-update.json` and `RELEASE-METADATA.json`;
4. public `SHA256SUMS`.

For prerelease packages the distinction is intentional:

```text
release:                 X.Y.Z-alpha.N
Debian package Version:  X.Y.Z~alpha.N-1
public asset filename:   atlantian-kernel_X.Y.Z.alpha.N-1_<arch>.deb
```

The updater validates Package/Version/Architecture fields and SHA-256, so the
filename is not package identity.

### Immutable release identity vs mutable presentation

Automatic publication never changes the identity or payload of an existing
release:

- an existing tag pointing at another SHA is a hard conflict;
- an existing release for another SHA is a hard conflict;
- tags are never retargeted automatically;
- a concurrent same-tag/same-SHA publication is idempotent.

Release **descriptions** are presentation metadata and are treated separately.
The Download Metrics workflow may idempotently normalize historical `Artifacts`
tables so they use the current per-file Downloads column. It does not retarget a
tag, replace release assets or alter release identity.

## Products

| Artifact | Purpose |
|---|---|
| `atlantian-<release>.img.xz` | versioned compressed SD system and matching NAND installer/recovery source |
| `atlantian-nand-<release>.tar.zst` | checksummed NAND raw-boot + SquashFS payload |
| three version-matched `.deb` files | AtlANTian platform/kernel/release updates; public filename is GitHub-safe while internal Debian Version stays canonical |
| `atlantian-update.json` | best-effort anonymous update-transaction counter marker; not trusted package identity |
| `RELEASE-METADATA.json` | release, Debian Snapshot, source and measured raw-image storage metadata |
| `SHA256SUMS` | hashes for the public downloadable payload names |

The SD filesystem is not copied wholesale into NAND.

## Download metrics

`Download Metrics` deploys one small `image-downloads.json` to GitHub Pages. It
contains:

- cumulative image downloads: sum of GitHub `download_count` for
  `atlantian-<release>.img.xz`;
- cumulative system-update starts: sum for `atlantian-update.json`;
- a keyed per-asset `download_count` for every file in every release.

A deterministic SHA-256-derived key represents each `(tag, asset name)` pair, so
release filenames do not have to be embedded directly in Shields JSONPath
expressions. Release Notes use those keys in the **Downloads** column of each
`Artifacts` table.

The metric workflow can start from a release event, manually, hourly, after a
`Build & Release` run completes, or when its own workflow definition is changed on
`main`. The last trigger exists so storage-policy maintenance can take effect
immediately without starting a system build. The `workflow_run` path has a cheap
gate: it refreshes Pages only if that Build & Release succeeded **and** a published
Release exists for its exact head SHA. Plan-only runs therefore do not cause a
Pages refresh. Automated releases use this completion path because a release
created by `GITHUB_TOKEN` does not recursively trigger the normal `release`
workflow event.

On the first applicable refresh after table-format changes, historical release
descriptions may be normalized idempotently from the actual GitHub asset list.
Later hourly runs update the Pages JSON without rewriting already-canonical
release descriptions.

The same workflow has a narrowly scoped `actions: write` pruning job. Cleanup is
fail-closed: it first proves that the newest published release still has a retained
`atlantian-verified-<SHA>` artifact. It then deletes only superseded verified
artifacts tied to already-published releases, duplicate verified artifacts for the
newest published SHA, and obsolete legacy version-named build artifacts. Verified
artifacts for unpublished SHAs are deliberately preserved for publication retry.
Tiny Pages artifacts keep their normal short retention and are not part of this
cleanup policy.

The update marker is downloaded by a real updater transaction only after user
confirmation; checks/notes do not fetch it. CI obtains old images from retained
SHA-sealed Actions artifacts instead of public Release assets, so production
validation does not increase either user-facing counter.

## Reproducible inputs and caches

Published builds pin:

- exact Debian Snapshot metadata;
- Linux source commit;
- U-Boot source commit.

Caches are performance optimizations only:

| Cache | Reused content |
|---|---|
| Debian | downloaded debootstrap package cache |
| Linux | pinned source/build tree keyed by source/config/toolchain inputs |
| U-Boot | pinned source tree |

Rootfs, final SD image and NAND products are rebuilt whenever a build is required.
The separate **verified workflow artifact** is what avoids rebuilding an already
successful source SHA during a publication retry.

A fresh repository needs no cache bootstrap.

## Fresh repository bootstrap

The source tree can be imported into a new GitHub repository without carrying
tags, releases, caches, workflow artifacts or secrets. Runtime release identity
is derived from `${{ github.repository }}` and stamped into the image/packages.

```text
source tree
  ↓
first qualifying push to new repository main
  ↓
no-release state is bootstrap-ready
  ↓
automatic build + verification + publication
  ↓
v<resolved-version> release
```

Only subsequent source changes use the five-qualifying-commit batch. Normal GitHub
publication uses scoped `GITHUB_TOKEN` permissions and requires no repository
secret.

## Build graph

```text
release line + pinned Debian Snapshot
        ↓
common Debian rootfs
        ├─ NAND specialization
        └─ SD specialization
        ↓
pinned Linux kernel/modules/DTB
        ↓
SD + NAND U-Boot/SPL
        ↓
SquashFS NAND base + raw boot bundle
        ↓
embed exact NAND bundle in SD rootfs
        ↓
FAT BOOT + ext4 ROOT raw image
        ↓
XZ compression + round-trip verification
        ↓
artifact/update/layout gates
        ↓
verified SHA artifact (raw + XZ, canonical package names)
        ↓
public filename/checksum normalization
        ↓
optional publication (XZ only)
```

NAND geometry/SPL/ECC details belong to [NAND](NAND.md). Physical validation
status belongs to [Hardware support](hardware-support-matrix.md).
