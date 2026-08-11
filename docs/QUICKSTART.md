# AtlANTian for SD — Quick Start

This page covers booting the unified AtlANTian image from microSD. The same image
also contains the matching NAND installer/recovery payload.

## What you need

| Item | Requirement |
|---|---|
| Board | Bitmain Antminer S9 control board |
| Storage | microSD large enough for the release image; 4 GiB or larger is convenient |
| Power | external 12 V board supply |
| Network | Ethernet with DHCP |
| Console | optional 3.3 V USB-UART, `115200 8N1` |
| Image | newest `atlantian-<release>.img` + `SHA256SUMS` |

> [!CAUTION]
> UART is **3.3 V logic**. Do not connect 5 V UART logic.

## 1. Verify the download

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

Optional provenance check; use the repository that published the image:

```sh
gh attestation verify atlantian-*.img --repo OWNER/REPOSITORY
```

The publishing repository is also recorded in the image as
`ATLANTIAN_RELEASE_REPOSITORY` in `/etc/os-release`.

## 2. Write the image

**Windows:** Rufus, Raspberry Pi Imager or Etcher in raw/DD mode.

**Linux:**

```sh
sudo dd if=atlantian-*.img of=/dev/sdX bs=8M status=progress conv=fsync
sync
```

Use the whole card device, not a partition.

## 3. First boot

1. Power off and select physical **SD** boot.
2. Insert microSD and connect Ethernet/UART as needed.
3. Apply 12 V.
4. Wait for automatic ROOT expansion and one reboot.
5. Connect through DHCP or UART.

| Default | Value |
|---|---|
| Hostname | `atlantian` |
| User | `root` |
| Password | empty for initial provisioning |
| UART | `115200 8N1` |
| RAM | detected by U-Boot; same image supports 512 MiB and 1 GiB boards |
| Boot policy | compiled `bootcmd`; persistent U-Boot environment disabled |

SD cold boot and software reboot are physically validated on both 512 MiB and
1 GiB boards.

> [!IMPORTANT]
> Set a password with `passwd` or install an SSH key before using an untrusted
> network.

## 4. Verify the system

```sh
cat /etc/os-release
uname -a
lsblk
networkctl
ip address
free -h
atlantian-fpga status
```

`/etc/os-release` intentionally reports `ID=debian` for compatibility while
`PRETTY_NAME` and `VARIANT` identify AtlANTian GNU/Linux. The AtlANTian semantic
release, Debian Snapshot, source revision and publishing repository are recorded
separately.

Expected SD storage is FAT `/boot` plus writable ext4 `/`, with ROOT expanded to
the card. AtlANTian does not impose a fixed Linux `mem=` cap.

## 5. Packages and updates

```sh
apt update
apt upgrade
apt install git python3 tmux
```

The factory root is built from a pinned Debian Snapshot; the running system uses
live repositories for its installed codename. Daily Snapshot refreshes do not
change the AtlANTian semantic release number.

AtlANTian SD updates:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

## Optional NAND installation

From the running SD system:

```sh
atlantian-nand-install
```

The installer handles backup, raw programming/verification and UBI creation,
then asks for the final physical **SD → NAND** jumper handoff. Fresh install and
cold NAND boot are validated on a 512 MiB board.

For later same-major AtlANTian NAND base updates, run **from NAND**:

```sh
atlantian-sysupgrade
```

It stages the verified target bundle on the paired recovery SD, then asks you to
switch **NAND → SD**. After SD reboot, the prepared maintenance transaction starts
at the next root login. There is no need to flash a separate target SD image.

See [NAND](NAND.md) and [Upgrading](UPGRADING.md).

## FPGA basics

```sh
atlantian-fpga status
atlantian-fpga apply <instance> <overlay.dtbo>
atlantian-fpga remove <instance>
```

A DT overlay describes hardware; the matching FPGA bitstream must implement it.

## Board behavior

| Topic | Behavior |
|---|---|
| RAM | runtime U-Boot probing; Linux receives detected bank through DT fixup |
| `reboot` | validated on both RAM variants for SD boot |
| `poweroff` | halts Linux; external 12 V remains present |
| suspend/hibernate | not advertised as validated |
| RTC | none fitted |
| USB | conflicted PS route disabled in base DT |
| NAND | raw MTD; installable from the same unified image |
| PL peripherals | matching bitstream + DT overlay required |

## Troubleshooting

| Symptom | Check |
|---|---|
| U-Boot stops at prompt | current image and FAT `boot.scr` |
| unexpected RAM | `grep MemTotal /proc/meminfo`; confirm fitted DDR |
| no Ethernet | `networkctl`, `ip link`, `ip address` |
| first-boot reboot | expected ROOT expansion behavior |
| SSH host-key warning | `ssh-keygen -R BOARD_IP` |

Further reading: [Installation](INSTALLATION.md), [NAND](NAND.md),
[hardware matrix](hardware-support-matrix.md), [Persistence](PERSISTENCE.md) and
[Security](../SECURITY.md).
