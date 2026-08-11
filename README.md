# AtlANTian GNU/Linux

[![License: GPL-2.0](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](LICENSE)

**AtlANTian** is a compact Debian-based GNU/Linux distribution for the Bitmain
Antminer S9 control board. It turns the Xilinx Zynq-7010 platform into a
general-purpose Linux/FPGA system and supports microSD and the on-board 256 MiB
raw NAND from **one ready-to-flash image**.

Generic Linux software sees a Debian system (`ID=debian`), while `PRETTY_NAME`,
`VARIANT` and AtlANTian release metadata preserve the distribution identity.
This keeps ordinary Debian tooling and third-party installers compatible without
hiding that the running product is AtlANTian GNU/Linux.

**Docs:** [Installation](docs/INSTALLATION.md) · [NAND](docs/NAND.md) ·
[Upgrading](docs/UPGRADING.md) · [Hardware](docs/hardware-support-matrix.md) ·
[Pipeline](docs/PIPELINE.md) · [all docs](docs/README.md)

## Release identity

AtlANTian versions intentionally include the Debian **major generation** while
keeping AtlANTian's own release lifecycle independent:

```text
13.1.0-alpha.1
│  │ │    └─ AtlANTian prerelease stage
│  │ └────── AtlANTian patch
│  └──────── AtlANTian release line
└─────────── Debian major generation
```

Examples: `13.1.0-alpha.1` → `13.1.0-beta.1` → `13.1.0-rc.1` → `13.1.0` →
`13.1.1` → `13.2.0`. A future Debian 14 line starts at `14.x.y`.

Routine Debian package/security refreshes **do not change the AtlANTian release
version**. The daily Debian watcher freezes the newest validated Snapshot for the
configured Debian generation; its exact timestamp and the source Git revision are
recorded separately as build metadata. A Debian-major transition is an explicit
release-line change, never an automatic daily-watcher action.

Debian packages use Debian-native prerelease ordering. For example, AtlANTian
`13.1.0-alpha.1` is packaged as `13.1.0~alpha.1-1`, so `dpkg` correctly orders it
before the eventual stable `13.1.0-1`.

## Storage modes

| Boot mode | Storage |
|---|---|
| **SD** | FAT BOOT + writable ext4 ROOT; ROOT expands on first boot |
| **NAND** | 16 MiB raw boot + 240 MiB UBI; SquashFS/Zstd read-only base + UBIFS/LZO writable upper |

The SD root embeds the checksummed NAND payload for the same release. NAND uses
the same Debian package profile, but stores it as a compressed immutable base
with writable OverlayFS state.

NAND visible root:

```text
SquashFS/Zstd lower
        +
UBIFS/LZO internal upper
        OR token-authorized ext4 upper on the recovery microSD
        ↓
     OverlayFS /
```

`atlantian-storage adopt` can use free space on the recovery SD without
repartitioning or erasing it. Without the card, NAND falls back to its internal
upper.

## Install

1. Verify `SHA256SUMS` and flash `atlantian-<release>.img`.
2. Select physical **SD** boot and power the board.
3. Wait for first-boot ROOT expansion and one reboot.
4. Set a root password or SSH key before using an untrusted network.

NAND installation is optional:

```sh
atlantian-nand-install
```

The installer verifies the board/NAND/ECC/payload, creates and verifies a raw+OOB
factory backup, asks once for `INSTALL`, programs and twice read-back-verifies raw
boot through SD U-Boot, writes/verifies UBI, then requests the physical **SD → NAND**
boot-source handoff.

Fresh destructive installation and cold boot from NAND through SPL → U-Boot →
kernel/initramfs → UBI/SquashFS/UBIFS/OverlayFS → systemd have been physically
validated on a 512 MiB board. Remaining hardware-validation items are tracked in
the [hardware matrix](docs/hardware-support-matrix.md).

## Packages and updates

SD and NAND use the same useful Debian/engineering userspace. Normal packages use
standard Debian repositories pinned to the installed codename:

```sh
apt update
apt upgrade
apt install git python3 tmux
```

| Operation | SD | NAND |
|---|---|---|
| Debian packages | normal APT | normal APT into the active upper |
| AtlANTian base/kernel/boot | `atlantian-sysupgrade` | `atlantian-sysupgrade` stages the verified NAND bundle on the paired recovery SD, then maintenance continues from SD |
| Debian-major transition | staged updater | clean NAND reinstall |

Same-major NAND base upgrades write the target immutable base and rebase selected
persistent state/package intent instead of copying a complete writable upper. See
[Upgrading](docs/UPGRADING.md).

## Platform

| Function | Status/policy |
|---|---|
| SoC | Xilinx Zynq-7010, dual Cortex-A9 + programmable logic |
| RAM | 512 MiB or 1 GiB DDR3, detected by U-Boot; no fixed Linux `mem=` cap |
| Debian | configured stable generation; immutable Snapshot input for reproducible factory builds |
| Kernel | pinned 6.12.y AtlANTian kernel with independent ABI revision and FPGA/NAND/UBI/SquashFS/UBIFS/OverlayFS support |
| SD boot | source-built pinned U-Boot; physically validated on 512 MiB and 1 GiB boards |
| NAND | 256 MiB Micron raw NAND; install and cold boot validated on 512 MiB, remaining gates tracked separately |
| Boot source | physical SD/NAND selection jumper |
| Ethernet / UART | Gigabit GEM/MACB + `ttyPS0` 115200 8N1 |
| FPGA | FPGA Manager/Region + configfs DT overlays + optional profiles |

NAND SPL uses a dedicated fixed-geometry reader for the supported Micron `2c:da`
part. It validates on-die ECC, skips factory-bad eraseblocks and uses bounded
ready waits instead of the full runtime NAND discovery path.

## Build

Clone the repository you intend to publish from, or use an archive that has been
committed to a fresh repository, then run:

```sh
cd atlantian
sudo bash scripts/bootstrap-host.sh
bash scripts/validate-release-inputs.sh
sudo -E bash scripts/build-incremental.sh all
```

The build does not depend on repository shell scripts retaining executable mode
bits, which makes a downloaded/re-uploaded source archive a supported bootstrap
path.

CI pins Debian/Linux/U-Boot inputs, verifies image/NAND capacity and boot/update
contracts, checks the embedded NAND bundle against the tested standalone bundle,
and validates normal `main` changes without creating a semantic release.
Publishing is an explicit manual action and is idempotent: existing repository
release state is inspected rather than treated as an early build error; incomplete
same-source publication can be reconciled, while an already published release
from another source revision is left unchanged. A fresh repository with no tag or
Release follows the clean first-publication path. See [Pipeline](docs/PIPELINE.md).
CI cannot replace real-board validation of bad-block placement, power-loss
recovery, extroot fallback or factory restore.

## Hardware boundaries

- `poweroff` halts Linux but cannot disconnect the external 12 V supply.
- suspend/hibernate is not advertised as a validated recoverable state.
- no battery-backed RTC is fitted.
- PS USB0 stays disabled because of the known MIO collision.
- raw+OOB NAND backups must not be restored with generic block-device `dd`.

## License

AtlANTian-specific source is **GPL-2.0-only**. Debian, Linux, U-Boot, FPGA
components and other third-party material retain their own licenses.
