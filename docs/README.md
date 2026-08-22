# AtlANTian documentation

AtlANTian publishes one microSD image that also contains the matching NAND
installer/recovery payload. Documentation is split by responsibility so each
behavior has one primary source of truth.

| Need | Read |
|---|---|
| get the board running from microSD | [SD Quick Start](QUICKSTART.md) |
| choose/install SD or NAND | [Installation](INSTALLATION.md) |
| understand NAND layout, ECC, SPL, UBI and recovery | [NAND](NAND.md) |
| update a running SD/NAND installation | [Upgrading](UPGRADING.md) |
| understand writable/persistent state | [Persistence](PERSISTENCE.md) |
| understand Debian Snapshot/major policy | [Debian lifecycle](DEBIAN-LIFECYCLE.md) |
| understand upstream tracking, CI, versioning, artifacts and publication | [Release pipeline](PIPELINE.md) |
| check board support, evidence and pin mappings | [Hardware support matrix](hardware-support-matrix.md) |
| run or record a physical board check | [Hardware validation plan](HARDWARE-VALIDATION.md) |
| security policy | [Security](../SECURITY.md) |
| contribution rules | [Contributing](../CONTRIBUTING.md) |

## Project invariants

- **Debian-compatible userspace:** generic software sees `ID=debian`; AtlANTian
  remains visible through `PRETTY_NAME`, `VARIANT` and release metadata.
- **Live runtime APT:** factory builds use a frozen Debian Snapshot, while
  installed systems receive normal Debian updates from live repositories for the
  installed codename.
- **One public image:** the SD runtime and its matching NAND installer/recovery
  payload ship together.
- **One common package profile:** SD and NAND derive from the same Debian base;
  NAND adds only storage/early-boot requirements.
- **Pinned factory inputs:** Debian Snapshot metadata plus exact Linux and U-Boot
  commits are fixed for every published build. Linux patch updates remain inside
  the selected LTS series; U-Boot automation accepts stable release tags only.
- **Conventional SD layout:** FAT BOOT + writable ext4 ROOT. The existing BOOT
  partition holds two checksummed kernel/DT FIT slots so platform updates are
  transactional without another rootfs or partition.
- **Known-good SD first stage:** online updates switch only the A/B FIT payload;
  early `BOOT.bin`/U-Boot are updated by flashing a complete newer image rather
  than by an unsafe in-place multi-file boot transaction.
- **Flash-aware NAND layout:** 16 MiB raw boot + UBI with read-only SquashFS lower
  and writable UBIFS OverlayFS upper.
- **Physical boot selection:** the board jumper selects SD or NAND; software does
  not replace that choice.
- **Evidence-based hardware status:** implementation and real-board validation are
  reported separately.

Release numbering, automatic upstream refresh/publication and Debian Snapshot
behavior are owned by [Pipeline](PIPELINE.md) and
[Debian lifecycle](DEBIAN-LIFECYCLE.md), rather than being redefined here.
