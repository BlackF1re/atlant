# AtlANTian on Antminer S9 NAND

This document is the source of truth for NAND geometry, ECC, raw boot layout,
SPL behavior, UBI and NAND recovery boundaries. Installation steps are summarized
in [Installation](INSTALLATION.md); platform updates are owned by
[Upgrading](UPGRADING.md).

AtlANTian installs from the unified microSD image into the on-board 256 MiB raw
NAND and then boots without a card. The paired recovery SD may optionally provide
a larger writable OverlayFS upper.

> [!IMPORTANT]
> Fresh destructive installation, cold NAND boot and warm reboot are physically
> validated on both 512 MiB and 1 GiB RAM board variants. Real factory-bad-block
> placement, adopted-SD fallback, interrupted/power-loss recovery and controlled
> factory restore remain hardware-validation items.

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
              OR token-authorized ext4 directory on paired recovery SD
```

The dynamic `overlay` volume is created with `ubimkvol -m`, so it receives the
space left after the static root volume and UBI reserves. `/tmp` and persistent
systemd journal storage are avoided on NAND; zram replaces persistent swap.

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

## NAND geometry and ECC

Supported stock device:

```text
Micron MT29F2G08ABAEAWP
ID         2c:da
capacity   256 MiB
eraseblock 128 KiB
page       2048 B
OOB        64 B
ECC        Micron on-die BCH 4/512
```

BootROM-facing boot objects, full U-Boot and Linux use the Micron on-die ECC
contract. Linux selects the chip ECC engine through Device Tree and records
BCH 4/512 geometry.

Full U-Boot may display `1 bit / 2048 B` for this path. That value is driver
bookkeeping for its on-die-ECC branch; it is **not** the physical correction
strength of the Micron engine.

The 16 MiB raw region is a boot/addressing boundary, not a separate ECC domain.

## SPL NAND path

NAND SPL intentionally does not run full runtime DM/MTD discovery. It uses a
small fixed-geometry reader for the supported Micron `2c:da` device. The reader:

- initializes PL353 NAND access;
- requires the expected device ID;
- enables and verifies Micron on-die ECC;
- checks factory bad-block markers;
- uses bounded, timer-independent ready polling.

This avoids the unnecessary runtime `nand_scan_ident()` path in SPL. Primary and
redundant U-Boot slots remain independent fallback targets.

## Bad blocks

AtlANTian keeps factory OOB bad-block markers authoritative and avoids forced
flash-BBT creation in the relevant Zynq NAND paths. Raw boot operations skip bad
blocks while preserving the logical payload stream. UBI owns bad-PEB handling
and wear-leveling in the 240 MiB data region.

The builder reserves a conservative bad-PEB budget and a minimum internal
writable budget; the installer repeats the relevant capacity check against the
actual NAND.

## Factory backup

Before destructive installation AtlANTian creates and verifies:

```text
/root/atlantian-factory-nand-backup/
├─ NAND-INFO.txt
├─ nand-raw-oob.bin
├─ nand-main-padded.bin
└─ SHA256SUMS
```

Backup reads use `nanddump --noecc`; the raw+OOB copy preserves the data/OOB view
and factory bad-block markers without reinterpreting them through the active ECC
layout.

> [!CAUTION]
> Never restore raw+OOB NAND with generic block-device `dd`.

Keep a copy of this backup outside the recovery SD before relying on factory
restore.

## Installation transaction

From the running unified SD image:

```sh
atlantian-nand-install
```

The destructive transaction is:

1. validate payload, geometry, ECC and capacity;
2. create/verify the factory backup and require literal `INSTALL`;
3. reboot in SD mode;
4. program and twice read-back-verify the raw boot region from SD U-Boot;
5. automatically resume in SD Linux;
6. create UBI, write/verify SquashFS and create the maximum-size UBIFS overlay;
7. request **SD → NAND** jumper handoff;
8. boot BootROM → SPL → NAND U-Boot → kernel/initramfs → OverlayFS/systemd.

`--resume` is a recovery continuation, not the normal install entry point.

## Writable storage

Useful status:

```sh
atlantian-storage status
cat /run/atlantian/storage-edition
cat /run/atlantian/overlay-mode
```

The paired recovery SD can be adopted with:

```sh
atlantian-storage adopt
```

AtlANTian stores `/.atlantian-extroot/{token,upper,work}` inside that card's ext4
ROOT partition, copies the current internal writable state, and records a matching
token internally. A matching card selects the SD upper at boot; an absent or
mismatched card falls back to internal UBIFS. The two uppers are independent
after adoption.

See [Persistence](PERSISTENCE.md) for persistence semantics.

## Validation boundary

Validated on real 512 MiB and 1 GiB hardware:

- verified raw+OOB pre-install backup;
- SD-U-Boot raw programming/read-back transaction;
- BootROM NAND start;
- dedicated SPL NAND reader and NAND U-Boot load;
- kernel/initramfs/DTB load from NAND;
- UBI + ubiblock + SquashFS + UBIFS + OverlayFS root;
- systemd multi-user boot, Ethernet/SSH and FPGA userspace startup;
- cold NAND boot and warm reboot;
- recovery-SD handoff and same-major NAND rebase.

Still requiring dedicated bench validation:

- actual factory-bad-block placement;
- adopted-SD upper and no-card fallback;
- interrupted/power-loss recovery;
- controlled factory raw+OOB restore.

See [Hardware support](hardware-support-matrix.md) for the status matrix and
[Upgrading](UPGRADING.md) for release-to-release NAND maintenance.
