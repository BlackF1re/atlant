# Build and release pipeline

This document owns CI/release behavior: triggers, automatic versioning, verified
artifacts, publication and reproducibility. Debian Snapshot discovery itself is
documented in [Debian lifecycle](DEBIAN-LIFECYCLE.md).

## What triggers a production build

`Build & Release` can start in three ways:

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

Documentation and workflow-only maintenance are intentionally excluded from the
full release-build path. `scripts/generate-release-notes.sh` is explicitly
excluded because it changes publication presentation rather than image contents.

After the first published release, automatic source publication batches five
qualifying commits since the last version tag. This prevents small incremental
changes from each producing a new large image. With no AtlANTian release tag,
`release-batch-state.sh` deliberately reports the threshold as ready so a freshly
imported repository publishes its first verified release immediately instead of
waiting for four unrelated follow-up edits.

A manual dispatch with `publish=true`, and the Debian Watch path, bypass this batch
threshold when an immediate verified release is needed.

Debian Watch does **not** bypass protected `main`. A changed Snapshot is committed
on a short-lived `maintenance/debian-snapshot-*` branch and proposed through a pull
request. Because `main` requires an up-to-date branch, the watcher asks GitHub for
the PR's exact synthetic merge candidate, exposes that immutable commit through a
short-lived `maintenance-validation/*` branch and explicitly runs the same
`CI / Validate` job on that merge-candidate SHA. It separately pins the original
base/head pair, rechecks `main`, the PR head and the merge candidate after CI, and
squash-merges through GitHub's protected-branch API only if all identities are
unchanged. The watcher then dispatches `Build & Release` against the resulting
exact `main` SHA with `origin=debian-watch`. Its inactivity heartbeat uses the
same protected merge path but never dispatches a release build.

A newer run on the same ref cancels an older in-progress release run. Publication
also requires the built SHA to still be the current `main` tip.

## Automatic release identity

The configured release line is:

```text
<Debian major>.<AtlANTian minor>.<AtlANTian patch>[-prerelease]
```

Examples:

```text
13.1.0-alpha.8
13.1.0-beta.1
13.1.0-rc.1
13.1.0
13.1.1
```

`config/release.env` defines the Debian generation, AtlANTian minor/initial patch
and prerelease channel. `scripts/resolve-release-version.sh` resolves the
publishable version from existing repository tags:

- a prerelease channel increments its numeric sequence (`alpha.8 → alpha.9`);
- changing channel starts from that channel's configured sequence
  (`alpha.N → beta.1`);
- a stable line increments the patch when that stable version already exists;
- rerunning the exact already-tagged source SHA resolves back to its existing
  version instead of inventing another one.

Source revision and Debian Snapshot timestamp are metadata, not release-ordering
components. Debian package metadata uses native prerelease ordering, e.g.
`13.1.0~alpha.8-1`.

A Debian-major transition remains explicit because it changes the release line
itself.

## Plan → build → publish

Production CI is deliberately split into separate jobs:

```text
plan
  ↓
build + verify (only when needed)
  ↓
seal SHA-specific verified artifact
  ↓
publish (only when requested and eligible)
```

A successful plan-only run is an orchestration result, not a claim that the
current `main` SHA has a binary image. Published releases are the source revisions
that completed the full binary build and verification path.

### Plan

The plan job resolves the version and decides whether a build is necessary.

For publication requests it checks:

1. whether the exact version is already published for this exact source SHA;
2. whether a non-expired verified artifact already exists for this source SHA.

If the release already exists for the same SHA, the workflow becomes an
idempotent no-op. If a verified artifact exists, publication can reuse it.

### Build and verify

A required build performs the full expensive path:

- source/build contract checks, including release-client/public-filename tests;
- frozen release-input validation;
- Debian rootfs build;
- pinned Linux build;
- SD/NAND U-Boot and NAND payload build;
- final unified raw image creation;
- XZ compression and raw/decompressed SHA-256 equivalence check;
- release artifact validation;
- SD image layout validation;
- NAND artifact validation;
- SD upgrade integration test;
- NAND rebase integration test;
- source-tree integrity check;
- Sigstore/GitHub build provenance attestation.

The raw `atlantian-<release>.img` remains inside the verified Actions artifact so
layout and release-upgrade gates can operate on the exact disk image without
using a public Release download. The user-facing asset is
`atlantian-<release>.img.xz`.

The SD upgrade integration test resolves an older published release by tag, but
loads its raw image from the matching SHA-sealed GitHub Actions artifact. It never
downloads the public Release image, so CI does not inflate user-facing download
metrics.

The build then adds:

```text
VERIFIED-SOURCE-SHA
VERIFIED-VERSION
```

and uploads `atlantian-verified-<full-source-SHA>` as a workflow artifact with a
90-day retention period. That artifact contains both the raw `.img` and verified
`.img.xz`, canonical Debian `.deb` filenames and its internal checksum manifest.

A failed publication therefore does not erase the successful build result. A
later publish retry for the same SHA can download, verify and reuse the sealed
artifact rather than rebuilding the OS.

### Publish

Publication is allowed only when:

- publication was requested by a qualifying push, Debian Watch, or manual
  `publish=true`;
- the plan/build path succeeded or a verified artifact was reused;
- the workflow source SHA is still current `main`;
- the target release/tag does not belong to another source revision.

Before any publication transformation, CI re-verifies the sealed artifact's
source marker, version marker, internal `SHA256SUMS`, raw/compressed image pair and
exact three-package `.deb` set.

`generate-release-notes.sh` then invokes `prepare-public-release.sh` on the local
publication copy. That step:

1. proves the compressed image still decodes to the sealed raw image;
2. keeps Debian package `Version` metadata unchanged;
3. normalizes only public prerelease `.deb` filenames from `~` to `.`;
4. creates the deterministic `atlantian-update.json` marker;
5. rewrites the **public** `SHA256SUMS` to cover exactly the downloadable payload
   names, not the private raw image;
6. generates Release Notes from those exact public filenames.

The raw `.img` remains in the local/Actions artifact but is deliberately **not**
uploaded to GitHub Releases.

Release assets are uploaded in this logical order:

1. `atlantian-<release>.img.xz`;
2. installed-system update payloads (`.deb` packages and NAND bundle);
3. `atlantian-update.json` and `RELEASE-METADATA.json`;
4. public `SHA256SUMS`.

For a prerelease, the distinction is intentional:

```text
Debian package Version:  13.1.0~alpha.8-1
public asset filename:    atlantian-kernel_13.1.0.alpha.8-1_<arch>.deb
```

The updater validates internal Package/Version/Architecture fields and SHA-256,
so the filename is not treated as package identity.

Existing release history is never rewritten automatically:

- an existing tag pointing at another SHA is a hard conflict;
- an existing release for another SHA is a hard conflict;
- automatic publication never retargets an existing tag;
- a concurrent release for the same tag/SHA is treated as an idempotent success.

## Products

| Artifact | Purpose |
|---|---|
| `atlantian-<release>.img.xz` | versioned, compressed SD system and matching NAND installer/recovery source; directly accepted by supported flashers |
| `atlantian-nand-<release>.tar.zst` | checksummed NAND raw-boot + SquashFS payload |
| three version-matched `.deb` files | AtlANTian platform/kernel/release updates; public filename is GitHub-safe while internal Debian Version stays canonical |
| `atlantian-update.json` | best-effort anonymous update-transaction counter marker; not trusted package identity |
| `RELEASE-METADATA.json` | release, Debian Snapshot, source and measured raw-image storage metadata |
| `SHA256SUMS` | hashes for exactly the public downloadable payload names |

The SD filesystem is not copied wholesale into NAND.

## Download-counter isolation

The README **Image Downloads** and **System Updates** badges are backed by one small
JSON file deployed to GitHub Pages. The metric workflow reads every GitHub Release,
sums `download_count` separately for names matching `atlantian-<release>.img.xz`
and exactly `atlantian-update.json`, then deploys both cumulative totals after
publication and hourly. Deployments create neither a branch nor repository commits.

The same Pages payload also stores a **per-asset** counter for every file in every
release. Each `(tag, asset name)` pair is mapped to a deterministic SHA-256-derived
key so filenames containing dots, tildes or other punctuation never have to be
embedded directly in a JSONPath expression. Release Notes use those values in the
third **Downloads** column of the `Artifacts` table through Shields dynamic JSON
badges. The badge therefore changes as GitHub's own `download_count` changes while
the release description itself remains static.

On the first metric refresh after this feature is introduced, the workflow
idempotently normalizes historical `Artifacts` tables from the actual GitHub asset
list and adds the same dynamic Downloads column. Later hourly runs do not rewrite
already-canonical release descriptions; they only refresh the Pages JSON.

The stable `atlantian-update.json` asset is the anonymous, best-effort marker for
actual updater transactions. CI never downloads either public metric asset: old raw
images come from retained SHA-sealed Actions artifacts instead.

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

Rootfs, final SD image and NAND products are rebuilt when a build is required.
The separate **verified workflow artifact** is what avoids rebuilding an already
successful source SHA during publication retry.

A fresh repository needs no cache bootstrap.

## Fresh repository bootstrap

The source tree can be imported into a new GitHub repository without carrying
tags, releases, caches, workflow artifacts or secrets. Runtime release identity
is derived from `${{ github.repository }}` and stamped into the image/packages.

Expected sequence:

```text
source tree
  ↓
first qualifying push to new repository main
  ↓
batch planner treats no-release state as bootstrap-ready
  ↓
automatic build + verification + publication
  ↓
v<resolved-version> release
```

Only subsequent source changes use the normal five-qualifying-commit batch.
The release workflow uses scoped `GITHUB_TOKEN` permissions; no repository secret
is required for normal GitHub publication.

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
