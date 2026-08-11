# AtlANTian on Antminer S9 NAND

AtlANTian installs from the unified microSD image into the on-board 256 MiB raw
NAND and then boots without a card. The same recovery SD may optionally provide
a larger writable OverlayFS upper.

> [!IMPORTANT]
> Fresh destructive installation and cold NAND boot are physically validated on
a 512 MiB board. Remaining hardware gates are: 1 GiB NAND boot, real bad-block
> cases, adopted-SD fallback, interrupted recovery and controlled factory restore.
> Keep the verified raw+OOB factory backup off-board.

## Storage architecture

```text
256 MiB raw NAND
├─ 16 MiB raw boot
│  ├─ SPL copies
│  ├─ primary + redundant NAND U-Boot
│  ├─ uImage
│  ├─ gzip initramfs
│  └─ DTB
└─ 240 MiB UBI
   ├─ rootfs   static UBI -> SquashFS/Zstd, read-only
   └─ overlay  dynamic UBI -> UBIFS/LZO, writable

visible /
└─ OverlayFS
   ├─ lower = SquashFS via ubiblock
   └─ upper = internal UBIFS
              OR token-authorized ext4 directory on recovery SD
```

The overlay volume is created with `ubimkvol -m`, so it receives all UBI space
remaining after the static root volume and UBI reserves. It is not a later
`autoresize` operation.

`/tmp` and systemd journal storage are volatile on NAND; zram replaces persistent
swap. NAND mounts use `noatime`.

## Raw boot layout

| Region | Offset | Reserved size |
|---|---:|---:|
| SPL area | `0x00000000` | 1 MiB |
| NAND U-Boot primary | `0x00100000` | 1 MiB |
| NAND U-Boot redundant | `0x00200000` | 1 MiB |
| Linux `uImage` | `0x00300000` | 9 MiB |
| initramfs `uInitrd` | `0x00C00000` | 3 MiB |
| device tree | `0x00F00000` | 1 MiB |
| UBI data region | `0x01000000` | remaining 240 MiB |

Raw reads/writes are bad-block aware and use the exact logical payload lengths,
not whole reserved slots.

## SPL NAND path

NAND SPL does **not** run the full runtime DM/MTD discovery path. It uses a small
fixed-geometry reader for the supported Micron device:

```text
ID         2c:da
capacity   256 MiB
eraseblock 128 KiB
page       2048 B
OOB        64 B
ECC        Micron on-die BCH 4/512
```

The reader initializes PL353 for NAND access, requires the expected Micron ID,
enables and verifies on-die ECC, checks factory bad-block markers and uses bounded
ready polling. It cannot hang indefinitely on the timer-dependent runtime NAND
probe path that is unnecessary in SPL.

Primary and redundant U-Boot slots remain independent fallback targets.

## ECC and bad blocks

Linux and full U-Boot use the same Micron on-die ECC contract. Linux selects the
chip ECC engine through the self-referenced `nand-ecc-engine` binding and records
BCH 4/512 geometry. U-Boot's displayed `1 bit / 2048 B` values are bookkeeping
for its on-die-ECC branch, not the physical correction strength of the Micron
engine.

AtlANTian disables forced flash-BBT creation in the relevant Zynq NAND paths so
factory OOB bad-block markers remain authoritative. UBI handles bad PEBs and
wear-leveling inside the 240 MiB data region.

The first 16 MiB is raw because BootROM/SPL/U-Boot require fixed-address boot
objects; it is not a different ECC domain.

## Factory backup

Before destructive installation AtlANTian creates and verifies:

```text
/root/atlantian-factory-nand-backup/
├─ NAND-INFO.txt
├─ nand-raw-oob.bin
├─ nand-main-padded.bin
└─ SHA256SUMS
```

Backup reads use `nanddump --noecc`; the raw+OOB copy preserves the NAND data/OOB
view and factory bad-block markers without reinterpreting them through the active
ECC layout.

> [!CAUTION]
> Never restore raw+OOB NAND with generic block-device `dd`.

## Installation

Boot the unified image with the jumper in **SD** mode and run:

```sh
atlantian-nand-install
```

Transaction:

1. verify board, embedded bundle, geometry, ECC and capacity;
2. create and verify the factory backup;
3. require literal `INSTALL`;
4. reboot once while still in SD mode;
5. SD U-Boot programs and twice read-back-verifies the complete raw boot region;
6. SD Linux automatically resumes, formats UBI, writes/verifies SquashFS and
   creates the maximum-size writable UBIFS overlay;
7. request the physical **SD → NAND** jumper handoff;
8. boot NAND through SPL → U-Boot → kernel/initramfs → OverlayFS/systemd.

`atlantian-nand-install --resume` is only a manual recovery continuation.

## Writable storage

Useful status:

```sh
atlantian-storage status
cat /run/atlantian/storage-edition
cat /run/atlantian/overlay-mode
```

### Adopt the recovery SD

After NAND boot:

```sh
atlantian-storage adopt
```

Only the paired install/recovery card is accepted. `adopt` requires literal
`ADOPT`, **does not repartition or erase the card**, and creates:

```text
/.atlantian-extroot/
├─ token
├─ upper/
└─ work/
```

The current internal writable state is copied to the card. At boot, a matching
token selects the SD upper; an absent/mismatched card falls back to internal
UBIFS. The two uppers are independent after adoption.

## Updates

Ordinary Debian packages update normally:

```sh
apt update
apt upgrade
```

They write to the active upper.

For a same-Debian-major AtlANTian NAND base/kernel/raw-boot update, run from the
live NAND system with the paired recovery SD inserted:

```sh
atlantian-sysupgrade
```

It downloads and verifies the target NAND bundle onto the preserved recovery SD,
then asks for the physical **NAND → SD** jumper change. After SD reboot, login
starts the prepared maintenance transaction. `atlantian-nand-upgrade` performs
the SD-side rebase/write stage; normal users do not need to download or flash a
separate target SD image.

The upgrade creates fresh uppers, restores persistent user/admin deltas and
replays manual package intent. Debian-major NAND transitions require a clean
reinstall. Routine Debian Snapshot refreshes do not themselves create a new
AtlANTian semantic release.

See [Upgrading](UPGRADING.md).

## Capacity policy

The builder sizes the static root volume from the actual SquashFS image and fails
unless the 240 MiB UBI region can retain the configured minimum writable budget,
conservative bad-PEB reserve and UBI overhead. The installer repeats the relevant
capacity check against the real NAND after bad blocks are known.

## Validation boundary

Validated on real 512 MiB hardware:

- destructive raw/UBI installation;
- SD-U-Boot raw write/read/compare transaction;
- BootROM NAND start;
- dedicated SPL NAND reader and NAND U-Boot load;
- kernel/initramfs/DTB load from NAND;
- Linux UBI + ubiblock + SquashFS + UBIFS + OverlayFS boot;
- systemd multi-user boot, Ethernet/SSH and FPGA userspace startup.

Still requiring dedicated bench validation: 1 GiB NAND boot, actual bad-block
placement, power-loss/interrupted recovery, external-upper fallback and factory
restore.

See [Installation](INSTALLATION.md), [Upgrading](UPGRADING.md),
[Persistence](PERSISTENCE.md) and the [hardware matrix](hardware-support-matrix.md).
