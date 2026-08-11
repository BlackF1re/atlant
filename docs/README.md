# AtlANTian documentation

AtlANTian publishes one SD image that is also the release-matched NAND
installer/recovery source.

| Topic | Source of truth |
|---|---|
| installation and first boot | [Installation](INSTALLATION.md) |
| short SD walkthrough | [SD Quick Start](QUICKSTART.md) |
| NAND layout, ECC, boot and extroot | [NAND](NAND.md) |
| SD/NAND update procedures | [Upgrading](UPGRADING.md) |
| persistent state | [Persistence](PERSISTENCE.md) |
| Debian release automation | [Debian lifecycle](DEBIAN-LIFECYCLE.md) |
| build and publication | [Release pipeline](PIPELINE.md) |
| physical/electrical evidence | [Hardware support matrix](hardware-support-matrix.md) |
| security | [Security](../SECURITY.md) |
| contributing | [Contributing](../CONTRIBUTING.md) |

## Core rules

- **Debian-compatible identity:** generic software sees `ID=debian`; human-facing
  identity remains AtlANTian through `PRETTY_NAME`, `VARIANT` and release metadata.
- **Semantic release line:** `<Debian major>.<AtlANTian minor>.<AtlANTian patch>[-prerelease]`;
  Debian Snapshot refreshes do not increment the AtlANTian release.
- **One public image:** normal SD runtime plus matching NAND installer/recovery.
- **One useful userspace:** SD and NAND derive from the same Debian package
  profile; NAND adds only early-boot/storage necessities.
- **Reproducible factory base:** Debian, Linux and U-Boot inputs are pinned.
- **Conventional SD:** FAT BOOT + writable ext4 ROOT.
- **Flash-aware NAND:** 16 MiB raw boot + UBI; SquashFS/Zstd lower,
  UBIFS/LZO writable upper and OverlayFS `/`.
- **Optional external upper:** only the paired recovery SD may be adopted; it
  remains bootable and is never repartitioned by `adopt`.
- **Clean NAND upgrades:** same-major base replacement creates fresh uppers,
  restores persistent deltas and replays manual package intent.
- **Physical boot selection:** SD/NAND source follows the board boot-source jumper.
- **Evidence-based status:** fresh destructive NAND install and cold boot are
  validated on a 512 MiB board; 1 GiB NAND boot, real bad-block cases,
  extroot/fallback, interrupted recovery and factory restore remain validation
  items until tested on hardware.

Package profiles: [`config/packages.base`](../config/packages.base) and
[`config/packages.nand`](../config/packages.nand).
