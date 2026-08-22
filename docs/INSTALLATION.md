# Installing AtlANTian

AtlANTian publishes one versioned compressed disk image:

```text
atlantian-<release>.img.xz
```

Decompression yields the exact raw image identified in `RELEASE-METADATA.json`.
The same image is the normal microSD system and the matching installer/recovery
source for on-board NAND. The physical boot-source jumper selects which medium
BootROM uses.

## Install to microSD

1. Download `atlantian-<release>.img.xz` and `SHA256SUMS` from the release page.
2. Verify the compressed image:

   ```sh
   sha256sum -c SHA256SUMS --ignore-missing
   ```

3. Write the image with a raw-image flasher such as Rufus, Raspberry Pi Imager or
   Etcher. If your installed version accepts `.img.xz`, use it directly;
   otherwise decompress it first and flash the resulting `.img`. On Linux, the
   compressed image can be streamed directly into the card as shown in
   [SD Quick Start](QUICKSTART.md).
4. Select physical **SD** boot, insert the card and power the board.
5. Wait for automatic ext4 ROOT expansion and one reboot.
6. Log in as `root` and set a password or SSH key before using an untrusted
   network.

The result is a normal writable Debian-compatible system. Its disk layout stays
simple—FAT BOOT + ext4 ROOT—but BOOT contains two checksummed FIT kernel/DT slots
inside the existing 48 MiB partition. They are used for power-loss-safe platform
updates without an extra partition or second rootfs. The factory image starts
from slot A and keeps an identical slot B as the initial rollback copy.

For exact flashing, provenance verification and first-boot checks, use
[SD Quick Start](QUICKSTART.md).

## Install the same release to NAND

Boot the unified image from SD, keep the jumper in **SD** mode and run:

```sh
atlantian-nand-install
```

The installation transaction:

1. validates board identity, embedded payload, NAND geometry/ECC and capacity;
2. creates and verifies a raw+OOB factory backup;
3. requires literal `INSTALL`;
4. reboots once while still in SD mode;
5. SD U-Boot programs and twice read-back-verifies the raw boot payload;
6. SD Linux automatically resumes, creates UBI, writes/verifies SquashFS and
   creates the writable UBIFS overlay;
7. requests the physical **SD → NAND** jumper handoff;
8. reboots from NAND.

`atlantian-nand-install --resume` exists only for manual recovery continuation.

Fresh destructive installation, cold NAND boot and warm reboot are physically
validated through multi-user Debian on both supported 512 MiB and 1 GiB RAM board
variants. Real bad-block placement, adopted-SD fallback, interrupted/power-loss
recovery and controlled factory restore remain separate validation items in the
[hardware matrix](hardware-support-matrix.md).

> [!CAUTION]
> The verified factory backup is stored on the recovery SD under
> `/root/atlantian-factory-nand-backup`. Copy it off-card if factory recovery
> matters.

NAND geometry, ECC, raw layout, bad blocks and recovery boundaries are documented
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

Use normal live APT for Debian packages and `atlantian-sysupgrade` for AtlANTian
platform releases. Debian package maintenance does not wait for a new image.
On SD, the custom kernel and matching DT are committed through the inactive A/B
FIT slot; the installed early `BOOT.bin`/U-Boot chain is intentionally not
rewritten by the online transaction. New complete images contain the currently
validated U-Boot. NAND platform updates stage maintenance through the paired
recovery SD; Debian-major NAND changes require a clean reinstall.

See [Upgrading](UPGRADING.md) for the complete update procedure.
