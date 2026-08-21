# AtlANTian GNU/Linux

[![Latest Release](https://img.shields.io/github/v/release/BlackF1re/atlantian?include_prereleases&sort=semver&label=release)](https://github.com/BlackF1re/atlantian/releases) [![Release Pipeline](https://img.shields.io/github/actions/workflow/status/BlackF1re/atlantian/build-release.yml?branch=main&label=release%20pipeline)](https://github.com/BlackF1re/atlantian/actions/workflows/build-release.yml) [![Release Date](https://img.shields.io/github/release-date-pre/BlackF1re/atlantian?display_date=published_at&label=released)](https://github.com/BlackF1re/atlantian/releases) [![Debian Snapshot](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2FBlackF1re%2Fatlantian%2Frefs%2Fheads%2Fmain%2Fconfig%2Fdebian-snapshot.env&search=DEBIAN_SNAPSHOT_TIMESTAMP%3D(%5Cd%7B4%7D)(%5Cd%7B2%7D)(%5Cd%7B2%7D)T%5Cd%7B6%7DZ&replace=%241-%242-%243&label=Debian%20snapshot)](https://github.com/BlackF1re/atlantian/blob/main/config/debian-snapshot.env) [![Image Downloads](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fblackf1re.github.io%2Fatlantian%2Fimage-downloads.json&query=%24.imageDownloads&label=image%20downloads&cacheSeconds=3600)](https://github.com/BlackF1re/atlantian/releases) [![System Updates](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fblackf1re.github.io%2Fatlantian%2Fimage-downloads.json&query=%24.systemUpdates&label=system%20updates&cacheSeconds=3600)](docs/UPGRADING.md)

**AtlANTian** is a compact Debian-based GNU/Linux distribution for the Bitmain
Antminer S9 control board. It turns the Xilinx Zynq-7010 into a general-purpose
Linux/FPGA system and publishes one ready-to-flash microSD image with the matching
optional NAND installer/recovery payload.

Generic software sees a normal Debian system (`ID=debian`); AtlANTian keeps its
own visible OS/release identity. Standard APT packages and normal Debian tooling
work as expected. Factory images are assembled from pinned Debian Snapshot,
Linux and U-Boot inputs, while installed systems use live Debian repositories for
their configured codename.

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

3. Write the image with a raw-image flasher such as Rufus, Raspberry Pi Imager or
   Etcher. If your installed version accepts `.img.xz`, select it directly;
   otherwise decompress it to `.img` first. On Linux, the image can be streamed
   through `xz` into `dd` as shown in [SD Quick Start](docs/QUICKSTART.md).
4. Power off the board, select physical **SD** boot, insert the card and connect
   Ethernet or UART.
5. Apply 12 V and wait for automatic ROOT expansion and one reboot.
6. Log in as `root` and set a password with `passwd` before using an untrusted
   network.

The initial root password is empty for first provisioning. See
[SD Quick Start](docs/QUICKSTART.md) for exact flashing, provenance and
troubleshooting steps.

## Supported hardware

| Function | Status |
|---|---|
| Zynq-7010 / dual Cortex-A9 | Ready |
| 512 MiB and 1 GiB DDR3 | Ready; detected by U-Boot |
| microSD boot | Ready; cold boot and reboot validated on both RAM variants |
| Gigabit Ethernet | Ready; DHCP |
| UART | Ready; `ttyPS0`, `115200 8N1` |
| 256 MiB Micron NAND | Ready; install, cold boot and reboot validated on 512 MiB and 1 GiB boards |
| FPGA | Ready; FPGA Manager/Region, configfs overlays and optional profiles |
| LEDs, buttons, XADC, watchdog | Ready |
| PS USB0 | Unavailable because of a known MIO routing collision |
| RTC | Not fitted |

See [Hardware support](docs/hardware-support-matrix.md) for the evidence/status
matrix and pin reference.

## SD and NAND

The same release image supports both modes.

| Mode | Storage model | Typical use |
|---|---|---|
| **SD** | FAT BOOT + writable ext4 ROOT; ROOT expands to the card; BOOT contains transactional A/B FIT kernel slots | first boot and normal development |
| **NAND** | 16 MiB raw boot + 240 MiB UBI; SquashFS lower + UBIFS upper | optional internal installation |

The SD BOOT partition has no extra update partition and no second rootfs. Kernel
and device tree are packed together in SHA-256-checked FIT images. A platform
update writes and verifies the inactive FIT slot, syncs it, and only then changes
the tiny active-slot marker; U-Boot automatically tries the other slot if the
selected FIT cannot boot. `BOOT.bin` and the early `u-boot.img` are deliberately
not rewritten by an online SD update, so the known-good first-stage chain is not
made vulnerable to an interrupted FAT rewrite. Fresh images contain the current
validated U-Boot.

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
matters. NAND internals and recovery boundaries are documented in
[NAND](docs/NAND.md).

## Packages and updates

Ordinary Debian maintenance is independent of AtlANTian image publication:

```sh
apt update
apt upgrade
apt install git python3 tmux
```

Runtime APT follows the installed Debian codename (`trixie` on the Debian 13
line), not the frozen Snapshot used to assemble the factory image. Repository
indexes are disposable and kept in a bounded 96 MiB tmpfs; downloaded `.deb`
payloads use normal storage-backed APT staging and are not retained after the
transaction. This avoids consuming a large fraction of RAM on 512 MiB boards
during a substantial upgrade.

AtlANTian platform updates use:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

| Operation | SD | NAND |
|---|---|---|
| Debian packages | normal live APT | normal live APT into the active upper |
| AtlANTian platform/kernel | verified package set; kernel+DTB committed through inactive A/B FIT slot | stage verified NAND bundle on the paired recovery SD, then continue maintenance from SD |
| Early SD U-Boot | updated by flashing a newer complete image, not by online package postinst | target raw boot is updated through the recovery-SD NAND transaction |
| Debian-major transition | explicit AtlANTian release-line transition | clean NAND reinstall |

For a prerelease `X.Y.Z-alpha.N`, Debian package metadata uses
`X.Y.Z~alpha.N-1`, while public GitHub `.deb` filenames replace `~` with `.`.
The updater verifies Package, Version, Architecture and the published checksum;
it does not infer package identity from the filename alone.

**Image Downloads** is the cumulative GitHub `download_count` for every published
AtlANTian SD image asset: current versioned `atlantian-<release>.img.xz` files plus
historical raw `.img` names such as `atlantian-<release>.img` and the legacy
`atlantian.img`. **System Updates** is the corresponding sum for the tiny
`atlantian-update.json` marker fetched once when a real update transaction starts.
The Pages-backed totals refresh after publication and hourly; a completed
`Build & Release` refreshes them only when that workflow actually published a
release. No AtlANTian installation or device identifier is added to these
requests. The badges are aggregate download-event counters, not unique user/device
counters, and GitHub/Shields caching can delay the displayed value. CI validation
uses retained SHA-sealed Actions artifacts and does not download either public
metric asset.

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

## Release and upstream model

AtlANTian versions include the Debian major generation:

```text
13.1.0-alpha.N
│  │ │    └─ prerelease channel and sequence
│  │ └────── AtlANTian patch
│  └──────── AtlANTian release line
└─────────── Debian major generation
```

Typical progression is `13.1.0-alpha.N` → `13.1.0-beta.N` →
`13.1.0-rc.N` → `13.1.0` → `13.1.1` → `13.2.0`. A Debian 14 line uses
`14.x.y`.

One daily **Upstream Base Watch** coalesces the reproducible build inputs instead
of maintaining unrelated release streams:

- Debian repository metadata is frozen to the matching Snapshot when it changes;
- Linux follows stable patch releases only inside the deliberately selected LTS
  series (currently `6.12.y`) and stores the exact upstream commit SHA;
- U-Boot follows only official stable `vYYYY.MM` tags; RC and branch heads are
  never automatic candidates, and both SD and NAND/SPL configurations must build
  before a candidate may enter protected `main`.

All changes discovered in one watcher run become one protected maintenance
transaction. Debian-only factory refreshes join the normal five-release-input
batch, because installed boards already receive Debian fixes through live APT.
A kernel or U-Boot change makes the current upstream transaction release-eligible
immediately, so the new image contains the newest accepted Debian Snapshot,
kernel and bootloader together instead of producing separate releases for each
component. A Debian-major change or Linux LTS-series change remains an explicit
project decision.

CI resolves the next publishable AtlANTian version from repository tags. The
first qualifying push in a fresh repository bootstraps a verified release;
ordinary release-input changes are otherwise batched until the fifth qualifying
commit. An explicit manual publication and an eligible upstream-watcher dispatch
may bypass that batch threshold. Documentation, workflow-only maintenance and
release-presentation-only changes do not independently require a binary release.

The **Release Pipeline** badge reports the result of the orchestration workflow;
a green plan-only run does not mean that every current `main` SHA has a binary
image. Published releases are the fully built and verified binary states.

Every published release records its exact Debian Snapshot, source revision,
Linux commit, U-Boot commit and publishing repository.

## Build from source

```sh
git clone https://github.com/BlackF1re/atlantian.git
cd atlantian
sudo bash scripts/bootstrap-host.sh
bash scripts/validate-release-inputs.sh
sudo -E bash scripts/build-incremental.sh all
```

A clean clone is a supported build path. `build-incremental.sh` prepares the
configured Linux source itself by fetching the exact immutable commit into
`out/linux-src`; it does not depend on a pre-populated CI cache or resolve a
movable version tag during the build. U-Boot is likewise built from its exact
configured commit.

The production workflow pins Debian, Linux and U-Boot inputs and validates image,
compression, NAND, update and source-integrity contracts. These are reproducible
**source/input identities**; AtlANTian does not claim that two arbitrary build
hosts will necessarily produce a bit-for-bit identical filesystem image because
host tool versions and filesystem metadata are not fully hermetic. A successful
production build is sealed as a SHA-specific verified workflow artifact before
publication; a later publication retry for the same SHA can reuse that artifact
instead of rebuilding it. The sealed artifact keeps the raw `.img` and canonical
Debian filenames for CI; publication normalizes only the public filenames and
writes a public `SHA256SUMS` for the downloadable payload.

See [Pipeline](docs/PIPELINE.md) for the CI/release contract.

## Hardware boundaries

- `poweroff` halts Linux but cannot disconnect the external 12 V supply.
- Suspend/hibernate is not advertised as a validated recoverable state.
- No battery-backed RTC is fitted.
- PS USB0 remains unavailable because of the known MIO collision.
- Raw+OOB NAND backups must not be restored with generic block-device `dd`.
- Automatic U-Boot tracking is still software validation; low-level boot changes
  remain subject to the hardware-validation boundary documented for the project.

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
