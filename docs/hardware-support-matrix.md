# Hardware support: Bitmain Antminer S9 control board

This matrix separates implemented software from physical validation.

| Status | Meaning |
|---|---|
| **Ready** | implemented and backed by current board/runtime evidence |
| **Validation** | implemented; this path still needs the listed real-board proof |
| **Profile** | framework support exists; matching FPGA bitstream/DT overlay owns the feature |
| **External** | board function outside Linux peripheral control |
| **Not fitted** | device is not populated |
| **Disabled** | intentionally disabled until routing/electrical safety is proven |

## Matrix

| Hardware / function | Status | Interface / evidence |
|---|---|---|
| XC7Z010 PS, dual Cortex-A9 | Ready | ARM/Zynq SMP |
| 512 MiB / 1 GiB DDR3 | Ready | runtime U-Boot probe; HIGHMEM; no fixed Linux `mem=` cap |
| source-built SD first stage | Ready | pinned U-Boot SPL + `u-boot.img`; cold boot/reboot validated on both RAM variants |
| microSD root | Ready | FAT BOOT + ext4 ROOT, first-boot expansion |
| 256 MiB Micron NAND visibility | Ready | PL35X MTD; raw+OOB backup path |
| AtlANTian NAND install/boot, 512 MiB board | **Ready** | destructive install and cold BootROM→SPL→U-Boot→Linux→OverlayFS→multi-user boot validated |
| AtlANTian NAND install/boot, 1 GiB board | **Validation** | software path shared; dedicated cold NAND boot still required |
| real NAND bad-block case | **Validation** | software is bad-block aware; physical bad-block placement still untested |
| adopted-SD extroot/fallback | **Validation** | implemented; paired-card activation/no-card fallback needs bench proof |
| interrupted recovery / factory restore | **Validation** | implemented safety/recovery paths still need controlled destructive tests |
| SD/NAND boot jumper | External | BootROM source is selected physically |
| Gigabit Ethernet | Ready | GEM/MACB, RGMII-ID, PHY address 1, DHCP |
| UART1 / J12 | Ready | `ttyPS0`, 115200 8N1 |
| D2/D3 LEDs | Ready | Linux LED class |
| S1/S2 buttons | Ready | Linux input; no destructive default action |
| buzzer / J1-J9 enables | Ready | named GPIO lines; high-Z until claimed |
| XADC | Ready | IIO + hwmon |
| Zynq watchdog | Ready | `/dev/watchdog0`; no automatic U-Boot arming |
| FPGA DevCfg/PCAP | Ready | FPGA Manager/Region + configfs overlays |
| D5-D8 | Profile | shipped `status-leds` profile |
| six fan headers | Profile | shared PWM + six tach inputs |
| nine hashboard headers | Profile | profile-specific interfaces |
| header I2C/SPI/PL UART | Profile | matching PL design + verified pin ownership required |
| audio/video/camera | Profile | matching PL design required; no GPU claimed |
| PS USB0 | Disabled | known MIO28-39 collision with hashboard enables/D3 |
| RTC | Not fitted | network time after cold boot |
| JTAG / 12 V power | External | recovery/power facilities |

## DDR and SD boot

U-Boot probes a 1 GiB maximum aperture and reports installed DDR through the DT
memory node. Observed Linux usable memory is roughly 473 MiB on 512 MiB boards
and 970–980 MiB on 1 GiB boards after reservations.

Production SD chain:

```text
BootROM -> SPL BOOT.bin -> u-boot.img -> boot.scr -> uImage + DTB -> ext4 root
```

`ENV_IS_NOWHERE` prevents persistent environment state from overriding the
factory-image boot policy.

## Physical boot selection

```text
jumper = SD   -> BootROM reads SD first stage
jumper = NAND -> BootROM reads NAND first stage
```

No Linux command or U-Boot environment substitutes for moving the jumper.

## NAND geometry and ECC

Observed device: Micron `MT29F2G08ABAEAWP`.

```text
capacity   256 MiB
eraseblock 128 KiB
page       2048 B
OOB        64 B
ECC        Micron on-die BCH 4/512
```

Linux and full U-Boot use the Micron on-die ECC path. Linux selects the chip ECC
engine through Device Tree. U-Boot may display `1 bit / 2048 B` for this branch;
that is driver bookkeeping, not the physical Micron correction strength.

### NAND SPL

The production NAND SPL uses a dedicated fixed-geometry reader for Micron
`2c:da`. It avoids full runtime `nand_scan_ident()` discovery, enables/verifies
on-die ECC, checks factory bad-block markers and uses bounded timer-independent
ready polling.

The 512 MiB board has completed a cold boot through this path into full Debian.

### Raw boot

```text
0x000000  SPL area
0x100000  NAND U-Boot primary
0x200000  NAND U-Boot redundant
0x300000  uImage
0xC00000  uInitrd
0xF00000  DTB
0x1000000 UBI region begins
```

SD U-Boot programs and twice read-back-verifies the raw boot transaction before
Linux is allowed to format/write UBI. Raw reads are bad-block aware.

### Linux data

```text
UBI rootfs   -> static volume -> SquashFS/Zstd -> ubiblock -> read-only lower
UBI overlay  -> dynamic volume -> UBIFS/LZO -> internal writable upper
visible /    -> OverlayFS
```

The overlay volume is created at maximum available size with `ubimkvol -m`.
UBI owns bad-PEB handling and wear-leveling. `/tmp` and journal storage are
volatile; zram replaces persistent swap.

## NAND validation evidence

Validated on a real 512 MiB board:

- verified raw+OOB pre-install backup;
- destructive raw boot programming and final compare;
- UBI/SquashFS/UBIFS creation;
- physical jumper handoff;
- BootROM NAND start and dedicated SPL reader;
- NAND U-Boot load and kernel/initramfs/DTB reads;
- Linux UBI/OverlayFS root;
- systemd multi-user boot, Gigabit Ethernet/SSH and FPGA userspace startup.

Not yet promoted:

- cold NAND boot on a 1 GiB board;
- real factory-bad-block placement;
- adopted-SD upper and no-card fallback;
- interrupted/power-loss recovery;
- controlled factory raw+OOB restore.

## Pin reference

| Signal | Mapping | Note |
|---|---|---|
| D2 | MIO15 | active-low |
| D3 red | MIO37 | active-high |
| D3 green | MIO38 | active-high |
| S1 | MIO47 | active-low |
| S2 | MIO51 | active-low |
| buzzer | MIO39 | unclaimed by default |
| J1-J9 enables | MIO28-MIO36 | inputs/high-Z until claimed |
| D5 | PL M19 / AXI GPIO bit 2 | Bank 35, 3.3 V, active-low |
| D6 | PL M17 / AXI GPIO bit 3 | Bank 35, 3.3 V, active-low |
| D7 | PL F16 / AXI GPIO bit 0 | Bank 35, 3.3 V, active-low |
| D8 | PL L19 / AXI GPIO bit 1 | Bank 35, 3.3 V, active-low |
| fan PWM | PL J18 | shared across six headers |
| fan tach 1-6 | PL F19/F20/G17/G18/J20/H20 | independent inputs |

## Boundaries

- `poweroff` halts Linux but cannot remove external 12 V.
- suspend/hibernate is not advertised as recoverable.
- USB0 stays disabled because its known PS route collides with MIO28-39 functions.
- a Linux/Zynq driver existing does not prove safe board routing.
- a full FPGA bitstream replaces the current PL design; independent full designs
  cannot simply be stacked.

See [NAND](NAND.md), [Installation](INSTALLATION.md) and
[SD Quick Start](QUICKSTART.md).
