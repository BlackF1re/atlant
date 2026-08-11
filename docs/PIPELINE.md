# Build and release pipeline

A production run builds one immutable source revision and one frozen Debian
Snapshot into one unified image plus update/audit artifacts.

## Release identity

AtlANTian release numbers are explicit configuration, not commit counters:

```text
<Debian major>.<AtlANTian minor>.<AtlANTian patch>[-prerelease]
```

For example, `13.1.0-alpha.1` has Debian package version
`13.1.0~alpha.1-1`. The source revision and Debian Snapshot timestamp are recorded
separately and do not participate in semantic release ordering.

Normal `main` changes and automatic Debian Snapshot refreshes run the complete
validation build with `publish=false`. A public GitHub Release is created only by
an explicit manual `workflow_dispatch` with `publish=true`.

Publication is deliberately idempotent:

- no tag and no Release: clean first publication;
- tag only, already on the built SHA: attach the Release to it;
- tag only, on another SHA: leave it untouched while building, then retarget it
  only after every build/publication gate succeeds;
- Release already exists for the built SHA: rebuild and reconcile canonical
  release assets with `--clobber`, allowing recovery from an interrupted upload;
- Release already exists for another SHA: fully validate the source tree but
  leave that published Release unchanged and finish successfully as a
  publication no-op.

An old repository therefore cannot poison a validation run merely because its
configured version has already been published.

## Fresh repository bootstrap

A source archive committed to a new GitHub repository is a supported first-class
installation path. The archive is not expected to carry Git tags, Releases,
Actions caches, workflow artifacts, secrets or any other GitHub-side state.

The release job derives its repository identity from `${{ github.repository }}`.
That identity is stamped into the built image as `ATLANTIAN_RELEASE_REPOSITORY`,
`HOME_URL`, support/documentation URLs and `/usr/lib/atlantian/release-repo`.
Consequently an image built after moving the source tree to another owner/repo
checks for AtlANTian updates in that new repository instead of silently calling
back to the historical one.

The expected bootstrap sequence is:

```text
source archive
    ↓
new empty GitHub repository
    ↓
commit/push archive contents to main
    ↓
automatic validation Build & Release run (publish=false)
    ↓
manual Build & Release dispatch with publish=true
    ↓
clean build + gates + v<version> Release in the new repository
```

No repository secret is required by the release workflow: it uses GitHub's
per-job `GITHUB_TOKEN`, with the exact `contents`, `id-token` and `attestations`
permissions declared in the job. GitHub Actions itself must of course be enabled;
an organization or enterprise policy can still impose a stricter ceiling than a
repository workflow is allowed to request.

`scripts/test-repository-portability.sh` is part of the cheap build preflight and
protects this migration contract from regressions.

## Products

| Artifact | Purpose |
|---|---|
| `atlantian-<release>.img` | normal SD system and NAND installer/recovery source |
| `atlantian-nand-<release>.tar.zst` | checksummed NAND raw-boot + SquashFS payload, also embedded in the image |
| three Debian-versioned `.deb` files | live AtlANTian updates for SD |
| `RELEASE-METADATA.json` | semantic release, package version, Debian Snapshot, source and measured SD/NAND footprint |
| `SHA256SUMS` | public payload hashes |

The SD filesystem is never copied wholesale into NAND.

## Build graph

```text
explicit AtlANTian release + pinned Debian Snapshot
        ↓
one common Debian rootfs
        ├─ NAND specialization
        └─ SD specialization
        ↓
shared pinned Linux kernel/modules/DTB
        ↓
final release stamp
        ↓
NAND initramfs
        ├─ SD/recovery U-Boot
        └─ NAND U-Boot + dedicated fixed-geometry SPL NAND reader
        ↓
SquashFS/Zstd NAND base + raw boot bundle
        ↓
embed exact tested bundle in SD rootfs
        ↓
FAT BOOT + ext4 ROOT unified image
        ↓
artifact/layout/update gates
        ↓
validation-only OR explicit current-main publication/reconciliation
```

The full build performs one debootstrap. NAND derives from the common rootfs and
adds only `config/packages.nand`/storage-specific policy.

## Immutable inputs and caches

Factory inputs are pinned: Debian Snapshot metadata, Linux commit and U-Boot
commit. Linux build cache invalidation covers the kernel source identity,
configuration/DTS/overlay inputs and toolchain fingerprint. U-Boot source is
hard-reset/cleaned before each SD/NAND flavor. Finished rootfs/release products
are not reused as opaque cache artifacts.

New repositories begin with empty caches and require no cache bootstrap. A cache
hit is an optimization only; it is never a correctness input.

Publishing a new or repaired release requires the built SHA to remain the current
`main` tip. Validation runs cannot publish regardless of their result.

## Debian watcher

The daily watcher is release-neutral:

```text
configured Debian generation
        ↓
new live repository metadata?
        ↓ yes
wait for exact Snapshot copy
        ↓
update Snapshot timestamp + SHA-256 pins
        ↓
commit Snapshot state only
        ↓
Build & Release (publish=false)
```

Availability of the next Debian major is reported separately. Automation never
edits the AtlANTian semantic release or silently changes `DEBIAN_MAJOR`/
`DEBIAN_CODENAME`.

## NAND build contract

```text
16 MiB raw boot
240 MiB UBI
  rootfs   static UBI -> SquashFS/Zstd
  overlay  dynamic UBI -> UBIFS/LZO
```

The static root volume is sized from the actual SquashFS image. The installer
creates the dynamic overlay with `ubimkvol -m`, allocating all UBI space remaining
after the root volume and UBI reserves; there is no later autoresize operation.

Publication fails unless the capacity model retains the configured minimum
internal writable budget, conservative bad-PEB reserve and UBI overhead.

NAND U-Boot embeds exact kernel/initramfs/DTB byte counts so bad-block-aware reads
cannot run into the next raw slot.

### SPL contract

NAND SPL uses a dedicated reader for the supported Micron `2c:da` geometry rather
than full runtime NAND discovery. Build contracts require:

- the required NAND/SMC nodes in the generated SPL DTB;
- SPL DM/OF prerequisites needed by the surrounding boot path;
- fixed geometry generated from `config/nand-layout.env`;
- Micron on-die ECC enable/verification;
- factory bad-block handling;
- bounded, timer-independent ready waits;
- no `nand_scan_ident()` or timer-delay APIs in the dedicated reader path;
- expected diagnostic strings in the final SPL binary;
- SPL size within its NAND eraseblock budget.

## Publication gates

Preflight and finished-artifact checks cover:

- fresh-repository portability and idempotent release-state handling;
- semantic release/package identity and Debian-compatible `os-release`;
- pinned source identities and common SD/NAND package policy;
- kernel early-root NAND/BCH/UBI/ubiblock/SquashFS/UBIFS/OverlayFS requirements;
- raw slot bounds and exact NAND U-Boot read lengths;
- SquashFS compression and 256 MiB capacity budget;
- unified FAT/ext4 image layout and firstboot contract;
- measured BOOT/ROOT filesystem occupancy and release metadata;
- embedded NAND bundle equality/checksums;
- installer backup → raw stage → auto-resume → handoff ordering;
- NAND clean-rebase/update contracts;
- release-to-release SD updater gate;
- SHA-256 and Sigstore build provenance.

## Hardware validation boundary

CI cannot emulate a real PL35X/BootROM NAND path. Real-board evidence therefore
remains separate from build success.

Physically validated on a 512 MiB board:

- destructive NAND installation;
- SD-U-Boot raw programming/read-back;
- cold BootROM → SPL → NAND U-Boot boot;
- kernel/initramfs/DTB load from NAND;
- UBI/ubiblock/SquashFS/UBIFS/OverlayFS root;
- multi-user Debian, Ethernet/SSH and FPGA userspace startup.

Still requiring dedicated hardware tests: 1 GiB NAND boot, real bad-block
placement, interrupted/power-loss recovery, adopted-SD fallback and controlled
factory restore.

Operator procedures: [Installation](INSTALLATION.md) and
[Upgrading](UPGRADING.md). NAND internals: [NAND](NAND.md).
