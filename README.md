# AtlANTian GNU/Linux

[![Latest Release](https://img.shields.io/github/v/release/BlackF1re/atlantian?include_prereleases&sort=semver&label=release)](https://github.com/BlackF1re/atlantian/releases) [![Build](https://github.com/BlackF1re/atlantian/actions/workflows/build-release.yml/badge.svg?branch=main)](https://github.com/BlackF1re/atlantian/actions/workflows/build-release.yml) [![Release Date](https://img.shields.io/github/release-date-pre/BlackF1re/atlantian?display_date=published_at&label=released)](https://github.com/BlackF1re/atlantian/releases) [![Debian Snapshot](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2FBlackF1re%2Fatlantian%2Frefs%2Fheads%2Fmain%2Fconfig%2Fdebian-snapshot.env&search=DEBIAN_SNAPSHOT_TIMESTAMP%3D(%5Cd%7B4%7D)(%5Cd%7B2%7D)(%5Cd%7B2%7D)T%5Cd%7B6%7DZ&replace=%241-%242-%243&label=Debian%20snapshot)](https://github.com/BlackF1re/atlantian/blob/main/config/debian-snapshot.env) [![Downloads](https://img.shields.io/github/downloads/BlackF1re/atlantian/total?label=downloads)](https://github.com/BlackF1re/atlantian/releases)

**AtlANTian** is a compact Debian-based GNU/Linux distribution for the Bitmain
Antminer S9 control board. It turns the Xilinx Zynq-7010 into a general-purpose
Linux/FPGA system and provides one ready-to-flash image for both microSD use and
optional installation to the on-board NAND.

Generic Linux software sees a Debian system (`ID=debian`), while AtlANTian keeps
its own visible OS and release identity. Standard APT packages and ordinary
Debian tooling work normally.

**Start here:** [Download latest release](https://github.com/BlackF1re/atlantian/releases/latest) ·
[SD Quick Start](docs/QUICKSTART.md) · [Installation](docs/INSTALLATION.md) ·
[NAND](docs/NAND.md) · [Hardware support](docs/hardware-support-matrix.md) ·
[All docs](docs/README.md)

## Quick start

### What you need

| Item | Requirement |
|---|---|
| Board | Bitmain Antminer S9 control board |
| Storage | microSD; 4 GiB or larger is convenient |
| Power | external 12 V board supply |
| Network | Ethernet with DHCP |
| Console | optional 3.3 V USB-UART, `115200 8N1` |
| Files | latest `atlantian-<release>.img` and `SHA256SUMS` |

> [!CAUTION]
> UART uses **3.3 V logic**. Do not connect a 5 V UART adapter.

### Install to microSD

1. Download the latest image and `SHA256SUMS` from
   [Releases](https://github.com/BlackF1re/atlantian/releases).
2. Verify the download:

   ```sh
   sha256sum -c SHA256SUMS --ignore-missing
   ```

3. Write the whole `.img` to the card with Rufus, Raspberry Pi Imager, Etcher or
   `dd` in raw mode.
4. Power off the board, select physical **SD** boot, insert the card and connect
   Ethernet or UART.
5. Apply 12 V and wait for automatic ROOT expansion and one reboot.
6. Connect through DHCP or UART, log in as `root`, then set a password with
   `passwd` before using an untrusted network.

The initial root password is empty for provisioning. For Linux `dd` examples,
first-boot checks and troubleshooting, see [SD Quick Start](docs/QUICKSTART.md).

## Supported hardware

| Function | Status |
|---|---|
| Zynq-7010 / dual Cortex-A9 | Ready |
| 512 MiB and 1 GiB DDR3 | Ready; detected automatically by U-Boot |
| microSD boot | Ready; cold boot and reboot validated on both RAM variants |
| Gigabit Ethernet | Ready; DHCP |
| UART | Ready; `ttyPS0`, `115200 8N1` |
| 256 MiB Micron NAND | Ready on 512 MiB board; 1 GiB cold NAND boot still needs dedicated validation |
| FPGA | FPGA Manager/Region, configfs overlays and optional profiles |
| LEDs, buttons, XADC, watchdog | Ready |
| PS USB0 | Disabled because of a known MIO routing collision |
| RTC | Not fitted |

The complete implementation/validation matrix is in
[Hardware support](docs/hardware-support-matrix.md).

## SD or NAND

The same release image supports both modes.

| Mode | Use | Storage |
|---|---|---|
| **SD** | recommended first boot and normal development | FAT BOOT + writable ext4 ROOT; ROOT expands to the card |
| **NAND** | optional internal installation | 16 MiB raw boot + 240 MiB UBI; read-only SquashFS base + writable UBIFS OverlayFS upper |

To install the running SD release to NAND, keep the board in **SD** boot mode and
run:

```sh
atlantian-nand-install
```

The installer verifies the board, NAND/ECC and payload, creates and verifies a
raw+OOB factory backup, programs and read-back-verifies NAND, then asks for the
physical **SD → NAND** jumper handoff.

NAND installation is destructive. Its verified factory backup is stored on the
SD system under `/root/atlantian-factory-nand-backup`; copy it elsewhere if you
may need factory restore.

For NAND layout, ECC, recovery and persistence details, see [NAND](docs/NAND.md)
and [Installation](docs/INSTALLATION.md).

## Packages and updates

AtlANTian is a normal Debian-compatible userspace:

```sh
apt update
apt upgrade
apt install git python3 tmux
```

AtlANTian system updates use:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

| Operation | SD | NAND |
|---|---|---|
| Debian packages | normal APT | normal APT into the active upper |
| AtlANTian base/kernel/boot | `atlantian-sysupgrade` | stages the verified bundle on the paired recovery SD and continues maintenance from SD |
| Debian-major transition | explicit AtlANTian release-line transition | clean NAND reinstall |

See [Upgrading](docs/UPGRADING.md) for the full update model.

## FPGA

Basic FPGA control is available from Linux:

```sh
atlantian-fpga status
atlantian-fpga apply <instance> <overlay.dtbo>
atlantian-fpga remove <instance>
```

A DT overlay describes the hardware exposed to Linux; the matching FPGA
bitstream must implement it. Shipped and planned interfaces are tracked in the
[hardware matrix](docs/hardware-support-matrix.md).

## Release model

AtlANTian versions include the Debian major generation:

```text
13.1.0-alpha.3
│  │ │    └─ prerelease stage
│  │ └────── AtlANTian patch
│  └──────── AtlANTian release line
└─────────── Debian major generation
```

Typical progression: `13.1.0-alpha.N` → `13.1.0-beta.N` → `13.1.0-rc.N` →
`13.1.0` → `13.1.1` → `13.2.0`. A Debian 14 line starts at `14.x.y`.

Meaningful `main` changes and validated Debian Snapshot refreshes automatically
build, test and publish the next release number. Documentation/workflow-only
maintenance does not spend a full release build. Debian-major transitions remain
explicit.

Debian packages use native prerelease ordering, for example
`13.1.0~alpha.3-1`. Every published release records its exact Debian Snapshot,
source revision and publishing repository in release metadata. The Snapshot badge
at the top reflects the current source tree.

## Build from source

```sh
git clone https://github.com/BlackF1re/atlantian.git
cd atlantian
sudo bash scripts/bootstrap-host.sh
bash scripts/validate-release-inputs.sh
sudo -E bash scripts/build-incremental.sh all
```

The release pipeline pins Debian, Linux and U-Boot inputs and validates image,
NAND, upgrade and source-integrity contracts. A successful build stores a
SHA-specific verified artifact before publication, so a publication retry can
reuse the already-tested output instead of rebuilding it.

See [Pipeline](docs/PIPELINE.md) for CI and reproducibility details.

## Hardware boundaries

- `poweroff` halts Linux but cannot disconnect the external 12 V supply.
- Suspend/hibernate is not advertised as a validated recoverable state.
- No battery-backed RTC is fitted.
- PS USB0 remains disabled because of the known MIO collision.
- Raw+OOB NAND backups must not be restored with generic block-device `dd`.

## Documentation

- [SD Quick Start](docs/QUICKSTART.md)
- [Installation](docs/INSTALLATION.md)
- [NAND and ECC](docs/NAND.md)
- [Upgrading](docs/UPGRADING.md)
- [Persistence](docs/PERSISTENCE.md)
- [Hardware support matrix](docs/hardware-support-matrix.md)
- [Build and release pipeline](docs/PIPELINE.md)
- [Security](SECURITY.md)

## License

AtlANTian-specific source is **GPL-2.0-only**. Debian, Linux, U-Boot, FPGA
components and other third-party material retain their own licenses.
