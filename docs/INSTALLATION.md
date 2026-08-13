# Installing AtlANTian

AtlANTian publishes one ready-to-flash image with a stable public filename:

```text
atlantian.img
```

The release tag and `RELEASE-METADATA.json` carry the exact AtlANTian version.
The image is the normal microSD system and the matching installer/recovery source
for on-board NAND. The physical boot-source jumper selects which medium BootROM
uses.

## Install to microSD

1. Download `atlantian.img` and `SHA256SUMS` from the release page.
2. Verify the image:

   ```sh
   sha256sum -c SHA256SUMS --ignore-missing
   ```

3. Flash the whole `.img` with Rufus, Raspberry Pi Imager, Etcher or `dd`.
4. Select physical **SD** boot, insert the card and power the board.
5. Wait for automatic ext4 ROOT expansion and one reboot.
6. Log in as `root` and set a password or SSH key before using an untrusted
   network.

The result is a normal writable Debian-compatible system. For exact flashing
commands, provenance verification and first-boot checks, use
[SD Quick Start](QUICKSTART.md).

## Install the same release to NAND

Boot the unified image from SD, keep the jumper in **SD** mode and run:

```sh
atlantian-nand-install
```

The installation transaction:

1. validate board identity, embedded payload, NAND geometry/ECC and capacity;
2. create and verify a raw+OOB factory backup;
3. require literal `INSTALL`;
4. reboot once while still in SD mode;
5. SD U-Boot program and twice read-back-verify the raw boot payload;
6. SD Linux automatically resume, create UBI, write/verify SquashFS and create the
   writable UBIFS overlay;
7. request the physical **SD → NAND** jumper handoff;
8. reboot from NAND.

`atlantian-nand-install --resume` exists only for manual recovery continuation.

Fresh destructive installation and cold NAND boot have been physically validated
through multi-user Debian on a 512 MiB board. The 1 GiB NAND path and remaining
destructive/failure-mode tests stay marked separately in the
[hardware matrix](hardware-support-matrix.md).

> [!CAUTION]
> The verified factory backup is stored on the recovery SD under
> `/root/atlantian-factory-nand-backup`. Copy it off-card if factory restore
> matters.

NAND geometry, ECC, raw layout, bad blocks and recovery rules are documented only
in [NAND](NAND.md).

## Optional external writable layer

After booting from NAND, the paired recovery SD can provide a larger writable
OverlayFS upper:

```sh
atlantian-storage adopt
```

`adopt` accepts only the paired recovery card, requires literal `ADOPT`, and
creates its private upper/work directory inside the existing ext4 ROOT
partition. It **does not repartition or erase the card**. If the card is absent
later, boot falls back to the independent internal UBIFS upper.

Storage semantics are documented in [Persistence](PERSISTENCE.md).

## Updates after installation

Use normal APT for Debian packages and `atlantian-sysupgrade` for AtlANTian
platform releases. NAND platform updates stage maintenance through the paired
recovery SD; Debian-major NAND changes require a clean reinstall.

See [Upgrading](UPGRADING.md) for the complete update procedure.
