# Build and release pipeline

This document owns CI/release behavior: triggers, automatic versioning, verified
artifacts, publication and reproducibility. Debian Snapshot discovery itself is
documented in [Debian lifecycle](DEBIAN-LIFECYCLE.md).

## What triggers a production build

`Build & Release` can start in three ways:

| Trigger | Build | Publish |
|---|---|---|
| push to `main` touching a source/build-input path | yes | yes, automatically |
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
full release-build path.

A newer run on the same ref cancels an older in-progress release run. Publication
also requires the built SHA to still be the current `main` tip.

## Automatic release identity

The configured release line is:

```text
<Debian major>.<AtlANTian minor>.<AtlANTian patch>[-prerelease]
```

Examples:

```text
13.1.0-alpha.3
13.1.0-beta.1
13.1.0-rc.1
13.1.0
13.1.1
```

`config/release.env` defines the Debian generation, AtlANTian minor/initial patch
and prerelease channel. `scripts/resolve-release-version.sh` resolves the
publishable version from existing repository tags:

- a prerelease channel increments its numeric sequence (`alpha.3 → alpha.4`);
- changing channel starts from that channel's configured sequence
  (`alpha.N → beta.1`);
- a stable line increments the patch when that stable version already exists;
- rerunning the exact already-tagged source SHA resolves back to its existing
  version instead of inventing another one.

Source revision and Debian Snapshot timestamp are metadata, not release-ordering
components. Debian packages use native prerelease ordering, e.g.
`13.1.0~alpha.3-1`.

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

### Plan

The plan job resolves the version and decides whether a build is necessary.

For publication requests it checks:

1. whether the exact version is already published for this exact source SHA;
2. whether a non-expired verified artifact already exists for this source SHA.

If the release already exists for the same SHA, the workflow becomes an
idempotent no-op. If a verified artifact exists, publication can reuse it.

### Build and verify

A required build performs the full expensive path:

- source/build contract checks;
- frozen release-input validation;
- Debian rootfs build;
- pinned Linux build;
- SD/NAND U-Boot and NAND payload build;
- final unified image creation;
- release artifact validation;
- SD image layout validation;
- NAND artifact validation;
- SD upgrade integration test;
- NAND rebase integration test;
- source-tree integrity check;
- Sigstore/GitHub build provenance attestation.

The SD upgrade integration test resolves an older published release by tag, but
loads its image from the matching SHA-sealed GitHub Actions artifact. It never
downloads the public Release image, so CI does not inflate user-facing download
metrics.

The build then adds:

```text
VERIFIED-SOURCE-SHA
VERIFIED-VERSION
```

and uploads `atlantian-verified-<full-source-SHA>` as a workflow artifact with a
90-day retention period.

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

Before upload, CI verifies the artifact's source marker, version marker,
`SHA256SUMS`, image count and exact three-package `.deb` set. Production releases
publish the image under the stable public name `atlantian.img` and add a tiny
`atlantian-update.json` marker used only for anonymous aggregate update counts.

Existing release history is never rewritten automatically:

- an existing tag pointing at another SHA is a hard conflict;
- an existing release for another SHA is a hard conflict;
- automatic publication never retargets an existing tag;
- a concurrent release for the same tag/SHA is treated as an idempotent success.

## Products

| Artifact | Purpose |
|---|---|
| `atlantian.img` | SD system and matching NAND installer/recovery source; stable name enables aggregate image-download metrics |
| `atlantian-nand-<release>.tar.zst` | checksummed NAND raw-boot + SquashFS payload |
| three version-matched `.deb` files | AtlANTian platform/kernel/release updates |
| `RELEASE-METADATA.json` | release, Debian Snapshot, source and measured storage metadata |
| `SHA256SUMS` | public payload hashes |
| `atlantian-update.json` | best-effort anonymous update-transaction counter marker; not trusted update payload |

The SD filesystem is not copied wholesale into NAND.

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
push to new repository main
  ↓
automatic build + verification + publication
  ↓
v<resolved-version> release
```

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
FAT BOOT + ext4 ROOT unified image
        ↓
artifact/update/layout gates
        ↓
verified SHA artifact
        ↓
optional publication
```

NAND geometry/SPL/ECC details belong to [NAND](NAND.md). Physical validation
status belongs to [Hardware support](hardware-support-matrix.md).
