# Installing AtlANTian

AtlANTian publishes one ready-to-flash image:

```text
atlantian-<release>.img
```

It is both the normal microSD system and the matching installer/recovery source
for the on-board NAND. The physical boot-source jumper selects SD or NAND.

## Install to microSD

1. Verify the download with `SHA256SUMS`.
2. Flash the whole `.img` with Rufus, Raspberry Pi Imager, Etcher or `dd`.
3. Select **SD** boot, insert the card and power the board.
4. Wait for automatic ext4 ROOT expansion and one reboot.
5. Set a root password or SSH key before using an untrusted network.

AtlANTian is now a normal writable Debian-compatible system. Generic software
sees `ID=debian`, while the human-facing OS identity remains AtlANTian GNU/Linux.
NAND installation is optional.

## Install the same release to NAND

Keep the jumper in **SD** mode and run:

```sh
atlantian-nand-install
```

The installer:

1. verifies the board, embedded payload, NAND geometry/ECC and capacity;
2. creates and verifies a raw+OOB factory backup;
3. asks once for literal `INSTALL`;
4. reboots once in SD mode;
5. SD U-Boot programs and twice read-back-verifies the raw boot area;
6. SD Linux automatically formats UBI, writes/verifies SquashFS and creates the
   writable UBIFS overlay;
7. asks for the physical **SD → NAND** jumper handoff;
8. reboots from NAND.

`atlantian-nand-install --resume` is only a manual recovery continuation.

Fresh destructive installation and cold NAND boot have been physically validated
on a 512 MiB board through the complete path to multi-user Debian. Remaining
hardware-validation items are listed in the
[hardware matrix](hardware-support-matrix.md).

> [!CAUTION]
> The verified factory backup is stored on the SD system by default under
> `/root/atlantian-factory-nand-backup`. Copy it off the card if factory restore
> matters.

For raw layout, SPL, ECC and capacity details, see [NAND](NAND.md).

## Optional larger writable layer

After booting NAND, insert the same recovery SD and run:

```sh
atlantian-storage adopt
```

The command accepts only the paired recovery card, requires literal `ADOPT`, and
creates an external OverlayFS upper inside its existing ext4 ROOT partition.
**It does not repartition or erase the recovery card.** Without the card, NAND
falls back to its internal UBIFS upper.

## Updates

| Operation | SD | NAND |
|---|---|---|
| Debian packages | normal APT | normal APT into active upper |
| AtlANTian base/kernel/boot | `atlantian-sysupgrade` | `atlantian-sysupgrade` stages the verified NAND bundle on the paired recovery SD; maintenance continues after switching to SD |
| Debian-major transition | explicit AtlANTian release-line transition | clean NAND reinstall |

Routine Debian Snapshot refreshes do not change the AtlANTian semantic release
number. For the full update model, see [Upgrading](UPGRADING.md).

See also [SD Quick Start](QUICKSTART.md), [Persistence](PERSISTENCE.md) and the
[hardware matrix](hardware-support-matrix.md).
