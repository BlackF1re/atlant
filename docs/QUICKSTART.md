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

**Windows / graphical tools:** Rufus, Raspberry Pi Imager and Etcher can open the
versioned `.img.xz` directly; select the whole microSD device and write in raw/DD
mode where the tool asks.

**Linux:** stream the XZ image directly into the whole card device:

```sh
xz -dc atlantian-*.img.xz | sudo dd of=/dev/sdX bs=8M status=progress conv=fsync
sync
```

Use the whole card device, not a partition. The release also keeps the exact raw
`.img` inside its verified CI artifact for regression testing, but only the
smaller `.img.xz` is published for normal users.

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
| Boot policy | compiled `bootcmd`; persistent U-Boot environment disabled |

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
card. `/etc/os-release` intentionally reports `ID=debian` for compatibility while
`PRETTY_NAME`/`VARIANT` identify AtlANTian.

## 6. Use Debian normally

```sh
apt update
apt upgrade
apt install git python3 tmux
```

AtlANTian platform updates are separate:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

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
| U-Boot stops at prompt | current image and FAT `boot.scr` |
| unexpected RAM | `grep MemTotal /proc/meminfo`; confirm fitted DDR |
| no Ethernet | `networkctl`, `ip link`, `ip address` |
| first-boot reboot | expected ROOT expansion behavior |
| SSH host-key warning after reflashing | `ssh-keygen -R BOARD_IP` |
