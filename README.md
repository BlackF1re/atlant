# AtlANTian GNU/Linux

[![Latest Release](https://img.shields.io/github/v/release/BlackF1re/atlantian?include_prereleases&sort=semver&label=release)](https://github.com/BlackF1re/atlantian/releases) [![Build](https://github.com/BlackF1re/atlantian/actions/workflows/build-release.yml/badge.svg?branch=main)](https://github.com/BlackF1re/atlantian/actions/workflows/build-release.yml) [![Release Date](https://img.shields.io/github/release-date-pre/BlackF1re/atlantian?display_date=published_at&label=released)](https://github.com/BlackF1re/atlantian/releases) [![Debian Snapshot](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2FBlackF1re%2Fatlantian%2Frefs%2Fheads%2Fmain%2Fconfig%2Fdebian-snapshot.env&search=DEBIAN_SNAPSHOT_TIMESTAMP%3D(%5Cd%7B4%7D)(%5Cd%7B2%7D)(%5Cd%7B2%7D)T%5Cd%7B6%7DZ&replace=%241-%242-%243&label=Debian%20snapshot)](https://github.com/BlackF1re/atlantian/blob/main/config/debian-snapshot.env) [![Image Downloads](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fapi.github.com%2Frepos%2FBlackF1re%2Fatlantian%2Freleases%3Fper_page%3D1&search=%22name%22%5Cs%2A%3A%5Cs%2A%22atlantian-%5B%5E%22%5D%2B%5C.img%5C.xz%22%5B%5Cs%5CS%5D%2A%3F%22download_count%22%5Cs%2A%3A%5Cs%2A%28%5B0-9%5D%2B%29&replace=%241&label=image%20downloads&cacheSeconds=300)](https://github.com/BlackF1re/atlantian/releases) [![System Updates](https://img.shields.io/github/downloads/BlackF1re/atlantian/atlantian-update.json.svg?displayAssetName=false&label=system%20updates)](docs/UPGRADING.md)

**AtlANTian** is a compact Debian-based GNU/Linux distribution for the Bitmain
Antminer S9 control board. It turns the Xilinx Zynq-7010 into a general-purpose
Linux/FPGA system and publishes one ready-to-flash image for microSD use and
optional installation to the on-board NAND.

Generic software sees a normal Debian system (`ID=debian`); AtlANTian keeps its
own visible OS/release identity. Standard APT packages and normal Debian tooling
work as expected.

**Start here:** [Releases](https://github.com/BlackF1re/atlantian/releases) ·
[SD Quick Start](docs/QUICKSTART.md) · [Installation](docs/INSTALLATION.md) ·
[NAND](docs/NAND.md) · [Hardware support](docs/hardware-support-matrix.md) ·
[All docs](docs/README.md)

## Quick start

| Item | Requirement |
|---|---|
| Board | Bitmain Antminer S9 control board |
| Storage | microSD; 4 GiB or larger is convenient |
| Power | external 12 V board supply |
| Network | Ethernet with DHCP |
| Console | optional 3.3 V USB-UART, `115200 8N1` |
| Files | current `atlantian-<release>.img.xz` and `SHA256SUMS` |

> [!CAUTION]
> UART uses **3.3 V logic**. Do not connect a 5 V UART adapter.

1. Download the versioned `.img.xz` and `SHA256SUMS` from
   [Releases](https://github.com/BlackF1re/atlantian/releases).
2. Verify the compressed image:

   ```sh
   sha256sum -c SHA256SUMS --ignore-missing
   ```

3. Rufus, Raspberry Pi Imager and Etcher can write the `.img.xz` directly. On
   Linux, stream it through `xz` into `dd` as shown in
   [SD Quick Start](docs/QUICKSTART.md).
4. Power off the board, select physical **SD** boot, insert the card and connect
   Ethernet or UART.
5. Apply 12 V and wait for automatic ROOT expansion and one reboot.
6. Log in as `root` and set a password with `passwd` before using an untrusted
   network.

The initial root password is empty for first provisioning. See
[SD Quick Start](docs/QUICKSTART.md) for flashing, provenance and troubleshooting.

## Supported hardware

| Function | Status |
|---|---|
| Zynq-7010 / dual Cortex-A9 | Ready |
| 512 MiB and 1 GiB DDR3 | Ready; detected by U-Boot |
| microSD boot | Ready; cold boot and reboot validated on both RAM variants |
| Gigabit Ethernet | Ready; DHCP |
| UART | Ready; `ttyPS0`, `115200 8N1` |
| 256 MiB Micron NAND | Ready on the validated 512 MiB-board path; 1 GiB NAND boot still requires bench validation |
| FPGA | FPGA Manager/Region, configfs overlays and optional profiles |
| LEDs, buttons, XADC, watchdog | Ready |
| PS USB0 | Disabled because of a known MIO routing collision |
| RTC | Not fitted |

See [Hardware support](docs/hardware-support-matrix.md) for the evidence/status
matrix and pin reference.

## SD and NAND

The same release image supports both modes.

| Mode | Storage model | Typical use |
|---|---|---|
| **SD** | FAT BOOT + writable ext4 ROOT; ROOT expands to the card | first boot and normal development |
| **NAND** | 16 MiB raw boot + 240 MiB UBI; SquashFS lower + UBIFS upper | optional internal installation |

To install the running SD release to NAND:

```sh
atlantian-nand-install
```

Keep the board in **SD** boot mode until the installer asks for the physical
**SD → NAND** jumper handoff. The installer validates geometry/ECC, creates and
verifies a raw+OOB factory backup, programs and read-back-verifies the raw boot
payload, then creates the UBI/SquashFS/UBIFS system.

The backup is stored on the recovery SD under
`/root/atlantian-factory-nand-backup`; copy it elsewhere if factory recovery
matters. NAND internals and recovery rules are owned by [NAND](docs/NAND.md).

## Packages and updates

Ordinary Debian maintenance stays ordinary:

```sh
apt update
apt upgrade
apt install git python3 tmux
```

AtlANTian platform updates use:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

| Operation | SD | NAND |
|---|---|---|
| Debian packages | normal APT | normal APT into the active upper |
| AtlANTian base/kernel/boot | in-place `atlantian-sysupgrade` | stage verified NAND bundle on the paired recovery SD, then continue maintenance from SD |
| Debian-major transition | explicit AtlANTian release-line transition | clean NAND reinstall |

**Image Downloads** reads GitHub's `download_count` for the versioned
`atlantian-<release>.img.xz` asset in the newest published release. **System
Updates** aggregates downloads of the tiny stable `atlantian-update.json` marker
when an actual AtlANTian update transaction starts. No device identifier is sent;
these are GitHub asset counters, not unique-user/device counts. GitHub and Shields
may cache the displayed value briefly. CI validation uses private Actions
artifacts and does not touch either counter.

The full user-facing update contract lives in [Upgrading](docs/UPGRADING.md).

## FPGA

Basic control is available from Linux:

```sh
atlantian-fpga status
atlantian-fpga apply <instance> <overlay.dtbo>
atlantian-fpga remove <instance>
```

The DT overlay describes the devices Linux should create; the matching FPGA
bitstream must implement them. Shipped and prospective interfaces are tracked in
the [hardware matrix](docs/hardware-support-matrix.md).

## Release model

AtlANTian versions include the Debian major generation:

```text
13.1.0-alpha.3
│  │ │    └─ prerelease channel and sequence
│  │ └────── AtlANTian patch
│  └──────── AtlANTian release line
└─────────── Debian major generation
```

Typical progression is `13.1.0-alpha.N` → `13.1.0-beta.N` →
`13.1.0-rc.N` → `13.1.0` → `13.1.1` → `13.2.0`. A Debian 14 line uses
`14.x.y`.

CI resolves the next publishable version from repository tags. A meaningful
source/build-input push to `main`, or a validated Debian Snapshot refresh,
builds, verifies and publishes the next version automatically. Documentation and
workflow-only maintenance are outside the release-build path. Debian-major
transitions remain explicit decisions.

Prereleases use Debian-native package ordering, for example
`13.1.0~alpha.3-1`. Every release records its exact Debian Snapshot, source
revision and publishing repository.

## Build from source

```sh
git clone https://github.com/BlackF1re/atlantian.git
cd atlantian
sudo bash scripts/bootstrap-host.sh
bash scripts/validate-release-inputs.sh
sudo -E bash scripts/build-incremental.sh all
```

The production workflow pins Debian, Linux and U-Boot inputs and validates image,
compression, NAND, update and source-integrity contracts. A successful build is
sealed as a SHA-specific verified workflow artifact before publication; a later
publication retry for the same SHA can reuse that artifact instead of rebuilding
it.

See [Pipeline](docs/PIPELINE.md) for the CI/release contract.

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
- [Debian lifecycle](docs/DEBIAN-LIFECYCLE.md)
- [Hardware support matrix](docs/hardware-support-matrix.md)
- [Hardware validation plan](docs/HARDWARE-VALIDATION.md)
- [Build and release pipeline](docs/PIPELINE.md)
- [Security](SECURITY.md)

## License

AtlANTian-specific source is **GPL-2.0-only**. Debian, Linux, U-Boot, FPGA
components and other third-party material retain their own licenses.
