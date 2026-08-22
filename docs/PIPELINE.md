# Build and release pipeline

This document owns CI/release behavior: triggers, upstream-input tracking,
automatic versioning, protected maintenance merges, verified artifacts,
publication and download-metric refreshes. Debian-generation policy itself is
documented in [Debian lifecycle](DEBIAN-LIFECYCLE.md).

## Production triggers

`Build & Release` can start in these ways:

| Trigger | Build | Publish |
|---|---|---|
| first qualifying push in a repository with no AtlANTian release tag | yes | yes, automatically |
| later push to `main` touching a source/build-input path | after 5 qualifying commits | yes, automatically |
| eligible Upstream Base Watch dispatch (compatibility origin `debian-watch`) | yes | yes, automatically |
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

After the first release, ordinary source publication batches five qualifying
release-input commits since the latest version tag. A fresh repository treats the
no-release state as bootstrap-ready so its first qualifying push publishes a
verified release immediately. Manual `publish=true` and an **eligible** upstream
watcher transaction bypass the five-commit threshold.

The daily upstream watcher does not create a separate release stream for each
component. Debian-only Snapshot changes remain batched because installed systems
already consume live Debian updates. A Linux or U-Boot input change makes the
current combined upstream transaction immediately release-eligible, so accepted
Debian, Linux and U-Boot inputs land in one image/release rather than three.

A newer run on the same ref cancels an older in-progress release run. Publication
also requires the built source SHA to remain the current `main` tip.

## Upstream Base Watch

The historical workflow filename is `.github/workflows/debian-watch.yml`, but the
workflow is now named **Upstream Base Watch**. It runs daily at 06:17 Asia/Tomsk
and tracks three reproducible factory inputs:

| Input | Automatic scope | Candidate gate |
|---|---|---|
| Debian | current configured codename; exact Snapshot metadata | Snapshot must contain the exact observed main/updates/security Release files and still publish `armhf` |
| Linux | patch releases inside the selected LTS series only, currently `6.12.y` | candidate is resolved to an immutable stable commit and the complete AtlANTian Kconfig/board contract is generated successfully |
| U-Boot | official stable `vYYYY.MM` tags only | both SD/recovery and NAND/SPL configurations must compile successfully |

Linux LTS-series changes are never automatic. U-Boot RC tags and arbitrary branch
heads are never automatic candidates. The watcher resolves a candidate tag to an
exact commit before it changes repository policy; production builds consume the
commit SHA, not the tag.

All candidate changes discovered in one watcher run are staged together. If any
changed, the watcher validates the combined release-input set, creates **one**
maintenance commit and merges it through protected `main`. If only Debian changed,
publication waits for the normal five-input threshold. If Linux or U-Boot changed,
the same combined transaction is released immediately after protected validation.

The internal dispatch string remains `origin=debian-watch` for compatibility with
the existing trusted publication gate in `build-release.yml`; the name no longer
means that the transaction necessarily contains Debian alone.

## Protected upstream maintenance

Upstream Base Watch never pushes directly to protected `main` and has no
protection bypass. When an upstream input changes it:

1. creates one short-lived `maintenance/upstream-base-*` branch and PR containing
   the whole Debian/Linux/U-Boot transaction;
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
8. verifies the resulting `main` SHA and, when release-eligible, explicitly
   dispatches `Build & Release` for that protected revision.

The status bridge records the result of real merge-candidate CI; it is not a
replacement for validation and cannot be written before that CI succeeds. The
explicit dispatches are necessary because events created with the workflow's
`GITHUB_TOKEN` do not recursively create the normal PR/push workflow chain.

A later no-change watcher run can recover the narrow window between a successful
upstream merge and a missed release dispatch. An unreleased Linux/U-Boot delta is
immediately redispatched. Debian-only deltas remain subject to the same five-input
threshold. The inactivity heartbeat uses the same protected merge path, changes no
release input and never dispatches a release build.

## Pull-request validation parity

The required `CI / Validate` check deliberately runs the cheap source contracts
that the production build runs before expensive rootfs/kernel work. That set
includes:

```text
test-build-orchestration.sh
test-runtime-policy.sh
test-release-versioning.sh
test-source-contracts.sh
test-update-leds.sh
test-release-metrics.sh
```

Keeping `test-release-metrics.sh` in the required PR gate is intentional: release
metrics/publication contracts must not be allowed to pass PR validation and then
fail only after an expensive production image build.

Changes to frozen release inputs additionally execute
`validate-release-inputs.sh`; workflow changes also pass the pinned-Action policy
and a small cache/artifact smoke test.

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

Source revision, Debian Snapshot timestamp, Linux version/commit and U-Boot
version/commit are release metadata and build identities, not separate release
number axes. For prereleases, Debian package metadata retains native ordering, for
example `X.Y.Z~alpha.N-1` for release `X.Y.Z-alpha.N`.

A Debian-major transition or Linux LTS-series transition remains explicit because
it changes project compatibility policy rather than merely advancing a stable
patch input.

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

### Source preparation

A clean source checkout is a first-class build path. `build-kernel.sh` calls
`prepare-kernel-source.sh`, which creates `out/linux-src` when absent, fetches the
**exact** `ATLANTIAN_KERNEL_COMMIT`, verifies `HEAD`, and verifies that the source
reports `ATLANTIAN_KERNEL_VERSION`. It never replaces that commit by resolving a
version tag during the build.

When a cache already contains the same kernel commit, tracked source transforms
are reset while in-tree build objects are retained. When the commit changes, the
source tree is detached at the new exact SHA and stale ignored/untracked objects
are removed. CI's explicit source-cache preparation remains a performance layer;
local correctness does not depend on that CI-only step.

U-Boot build scripts similarly fetch and verify only
`ATLANTIAN_UBOOT_COMMIT`. The watcher may use an official stable tag to discover a
new candidate, but the tag stops being an authority once its commit has been
recorded.

### Build and verify

A required build performs the expensive path:

- source/build contract checks, including release-client/public-filename and
  release-metrics tests;
- frozen release-input validation;
- Debian rootfs build;
- exact-pinned Linux build;
- SD/NAND U-Boot and NAND payload build;
- unified raw image creation;
- XZ compression plus raw/decompressed SHA-256 equivalence check;
- release artifact validation;
- SD image layout and transactional FIT-slot validation;
- NAND artifact validation;
- SD upgrade integration test;
- NAND rebase integration test;
- source-tree integrity check;
- GitHub/Sigstore build provenance attestation.

The SD BOOT partition contains two checksummed FIT images,
`atlantian-A.itb` and `atlantian-B.itb`. Each FIT binds the kernel and matching DTB
into one SHA-256-checked boot object. The factory image begins on slot A. Online
kernel updates stage the new FIT into the inactive slot and change only a small
active-slot marker after write verification and `sync`; the other slot remains a
rollback candidate. The existing 48 MiB FAT BOOT partition is reused, so there is
no second rootfs or dedicated update partition.

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

and uploads `atlantian-verified-<full-source-SHA>`. The full artifact is retained
until publication succeeds. After publication the storage-pruning workflow keeps
the newest published release's compact verified artifact needed by the next
release-upgrade test and removes superseded published build artifacts. Unpublished
verified artifacts remain eligible for publication retry.

### Publish

Publication is allowed only when:

- publication was requested by a qualifying push, eligible upstream transaction
  or manual `publish=true`;
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

Release descriptions are presentation metadata and are treated separately. The
Download Metrics workflow may idempotently normalize historical `Artifacts`
tables so they use the current per-file Downloads column. It does not retarget a
tag, replace release assets or alter release identity.

## Runtime update model

Factory reproducibility and runtime maintenance deliberately use different
sources:

| Layer | Factory/release build | Installed system |
|---|---|---|
| Debian userspace | frozen Snapshot | live repositories for installed codename via ordinary APT |
| AtlANTian kernel/DT | exact configured Linux commit | verified AtlANTian release package; transactional A/B FIT on SD |
| SD early U-Boot | exact configured U-Boot commit in a freshly flashed image | deliberately retained during online package update |
| NAND early boot/base | release-matched raw boot + SquashFS bundle | same-major maintenance via paired recovery SD |

This means a board does **not** wait for a new AtlANTian image to receive normal
Debian security updates. Conversely, ordinary Debian APT cannot silently replace
the board-specific kernel/DT/U-Boot contract with an unrelated generic package.

The APT runtime policy keeps repository indexes in a bounded 96 MiB tmpfs.
Downloaded `.deb` files use normal storage-backed APT staging and are configured
not to be retained after installation. The prior `size=50%` RAM-backed archive
model is intentionally not used, because large package transactions must remain
viable on 512 MiB boards.

## Products

| Artifact | Purpose |
|---|---|
| `atlantian-<release>.img.xz` | versioned compressed SD system and matching NAND installer/recovery source |
| `atlantian-nand-<release>.tar.zst` | checksummed NAND raw-boot + SquashFS payload |
| three version-matched `.deb` files | AtlANTian platform/kernel/release updates; public filename is GitHub-safe while internal Debian Version stays canonical |
| `atlantian-update.json` | best-effort anonymous update-transaction counter marker; not trusted package identity |
| `RELEASE-METADATA.json` | release, Debian Snapshot, Linux/U-Boot source identity and measured raw-image storage metadata |
| `SHA256SUMS` | hashes for the public downloadable payload names |

The SD filesystem is not copied wholesale into NAND.

## Download metrics

`Download Metrics` deploys one small `image-downloads.json` to GitHub Pages. It
contains:

- cumulative image downloads: sum of GitHub `download_count` for every published
  AtlANTian SD image asset, including current versioned
  `atlantian-<release>.img.xz`, historical `atlantian-<release>.img`, and the
  one legacy unversioned `atlantian.img` asset;
- cumulative system-update starts: sum for `atlantian-update.json`;
- a keyed per-asset `download_count` for every file in every release.

A deterministic SHA-256-derived key represents each `(tag, asset name)` pair, so
release filenames do not have to be embedded directly in Shields JSONPath
expressions. Release Notes use those keys in the **Downloads** column of each
`Artifacts` table.

The metric workflow can start from a release event, manually, hourly, after a
`Build & Release` run completes, or when its own workflow definition is changed on
`main`. The `workflow_run` path has a cheap gate: it refreshes Pages only if that
Build & Release succeeded **and** a published Release exists for its exact head
SHA. Plan-only runs therefore do not cause a Pages refresh.

Refresh validates the paginated Release inventory before deploying Pages and
fails closed on an empty/incomplete response. Pruning and release-description
backfill consume the same validated snapshot instead of making independent
Release-inventory assumptions.

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
- exact Linux source commit and selected LTS series;
- exact U-Boot source commit from an accepted stable release.

These are reproducible **input identities**, not a claim that arbitrary build
hosts necessarily emit bit-for-bit identical disk images. The hosted Ubuntu
runner toolchain and filesystem metadata are not fully hermetic. Production
artifacts are instead tied to the exact source/workflow execution by their sealed
checksums and build provenance.

Caches are performance optimizations only:

| Cache | Reused content |
|---|---|
| Debian | downloaded debootstrap package cache |
| Linux | pinned source/build tree keyed by source/config/toolchain inputs |
| U-Boot | pinned source tree |

Rootfs, final SD image and NAND products are rebuilt whenever a build is required.
The separate verified workflow artifact is what avoids rebuilding an already
successful source SHA during a publication retry. A fresh repository or clean
local clone needs no cache bootstrap.

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

Only subsequent ordinary source changes use the five-qualifying-commit batch.
Normal GitHub publication uses scoped `GITHUB_TOKEN` permissions and requires no
repository secret.

## Build graph

```text
release line + pinned Debian Snapshot + exact Linux/U-Boot commits
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
FAT BOOT (A/B FIT) + ext4 ROOT raw image
        ↓
XZ compression + round-trip verification
        ↓
artifact/update/layout gates
        ↓
verified SHA artifact
        ↓
public filename/checksum normalization
        ↓
optional publication
```

NAND geometry/SPL/ECC details belong to [NAND](NAND.md). Physical validation
status belongs to [Hardware support](hardware-support-matrix.md).
