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
| understand Debian Snapshot automation/major transitions | [Debian lifecycle](DEBIAN-LIFECYCLE.md) |
| understand CI, versioning, artifacts and publication | [Release pipeline](PIPELINE.md) |
| check board support, evidence and pin mappings | [Hardware support matrix](hardware-support-matrix.md) |
| security policy | [Security](../SECURITY.md) |
| contribution rules | [Contributing](../CONTRIBUTING.md) |

## Project invariants

- **Debian-compatible userspace:** generic software sees `ID=debian`; AtlANTian
  remains visible through `PRETTY_NAME`, `VARIANT` and release metadata.
- **One public image:** the SD runtime and its matching NAND installer/recovery
  payload ship together.
- **One common package profile:** SD and NAND derive from the same Debian base;
  NAND adds only storage/early-boot requirements.
- **Pinned factory inputs:** Debian Snapshot metadata, Linux and U-Boot inputs are
  fixed for every built release.
- **Conventional SD layout:** FAT BOOT + writable ext4 ROOT.
- **Flash-aware NAND layout:** 16 MiB raw boot + UBI with read-only SquashFS lower
  and writable UBIFS OverlayFS upper.
- **Physical boot selection:** the board jumper selects SD or NAND; software does
  not replace that choice.
- **Evidence-based hardware status:** implementation and real-board validation are
  reported separately.

Release numbering, automatic publication and Debian Snapshot behavior are owned by
[Pipeline](PIPELINE.md) and [Debian lifecycle](DEBIAN-LIFECYCLE.md), rather than
being redefined here.
