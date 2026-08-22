# AtlANTian SD Quick Start

This page gets a board from a release image to a working SD boot. For NAND,
updates and hardware internals, follow the linked topic documents instead of this
quick-start path.

## 1. Requirements

| Item | Requirement |
|---|---|
| Board | Bitmain Antminer S9 control board |
| Storage | microSD large enough for the image; 4 GiB or larger is convenient |
| Power | external 12 V board supply |
| Network | Ethernet with DHCP |
| Console | optional 3.3 V USB-UART, `115200 8N1` |
| Image | current `atlantian-<release>.img.xz` + `SHA256SUMS` |

> [!CAUTION]
> UART is **3.3 V logic**. Do not connect 5 V UART logic.

## 2. Verify the download

Keep the `.img.xz` compressed while verifying it:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

Optional GitHub provenance verification:

```sh
gh attestation verify atlantian-*.img.xz --repo OWNER/REPOSITORY
```

Use the repository that published the image. It is also recorded inside the
system as `ATLANTIAN_RELEASE_REPOSITORY`.

## 3. Write the image

Use a raw-image writer such as Rufus, Raspberry Pi Imager or Etcher. If the
installed version accepts `.img.xz`, select the compressed release asset directly.
If it does not, decompress the file first and write the resulting `.img` as a raw
disk image.

On Linux, no intermediate `.img` file is required:

```sh
xz -dc atlantian-*.img.xz | sudo dd of=/dev/sdX bs=8M status=progress conv=fsync
sync
```

Use the whole card device, not a partition. The release keeps the exact raw `.img`
inside its verified CI artifact for regression testing, but only `.img.xz` is
published as the normal user download.

## 4. First boot

1. Power off and select physical **SD** boot.
2. Insert microSD and connect Ethernet/UART as needed.
3. Apply 12 V.
4. Wait for automatic ROOT expansion and one reboot.
5. Connect through DHCP or UART.
6. Log in as `root`.

| Default | Value |
|---|---|
| Hostname | `atlantian` |
| User | `root` |
| Password | empty for first provisioning |
| UART | `115200 8N1` |
| RAM | detected by U-Boot; same image supports 512 MiB and 1 GiB boards |
| Boot policy | immutable U-Boot environment; FIT slot A first, slot B rollback |

SD cold boot and software reboot are physically validated on both 512 MiB and
1 GiB boards.

> [!IMPORTANT]
> Run `passwd` or install an SSH key before using an untrusted network.

## 5. Verify the system

```sh
cat /etc/os-release
uname -a
lsblk
networkctl
ip address
free -h
atlantian-fpga status
```

Expected storage is FAT `/boot` plus writable ext4 `/`, with ROOT expanded to the
card. Inside the same FAT partition AtlANTian keeps two SHA-256-checked FIT kernel
slots (`atlantian-A.itb` and `atlantian-B.itb`) for transactional platform
updates; no extra update partition or second rootfs is created.

`/etc/os-release` intentionally reports `ID=debian` for compatibility while
`PRETTY_NAME`/`VARIANT` identify AtlANTian.

## 6. Use Debian normally

```sh
apt update
apt upgrade
apt install git python3 tmux
```

These commands use live Debian repositories for the installed codename and do not
wait for a new AtlANTian image. Repository indexes are kept in a bounded volatile
workspace; package downloads use storage-backed APT staging so large transactions
do not reserve half of RAM on a 512 MiB board.

AtlANTian platform/kernel updates are separate:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

On SD, a platform update writes the new kernel+DTB FIT into the inactive slot,
verifies/syncs it, and only then switches the active-slot marker. The old slot is
left as automatic fallback. Early `BOOT.bin`/U-Boot are intentionally not
rewritten during this online transaction; a freshly flashed image contains the
current validated bootloader.

See [Upgrading](UPGRADING.md) before a platform or Debian-major transition.

## Next steps

- install the same release to NAND: [Installation](INSTALLATION.md)
- understand NAND/ECC/recovery: [NAND](NAND.md)
- check supported peripherals and pins: [Hardware support](hardware-support-matrix.md)
- understand writable storage: [Persistence](PERSISTENCE.md)
- security policy: [Security](../SECURITY.md)

## Troubleshooting

| Symptom | Check |
|---|---|
| flasher does not accept `.img.xz` | decompress to `.img`, then write that raw image |
| U-Boot stops at prompt | current image, FAT `boot.scr`, `atlantian-A.itb`/`atlantian-B.itb` |
| active FIT fails | boot script automatically attempts the other complete FIT slot |
| unexpected RAM | `grep MemTotal /proc/meminfo`; confirm fitted DDR |
| no Ethernet | `networkctl`, `ip link`, `ip address` |
| first-boot reboot | expected ROOT expansion behavior |
| SSH host-key warning after reflashing | `ssh-keygen -R BOARD_IP` |
