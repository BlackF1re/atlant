# Hardware support: Bitmain Antminer S9 control board

This matrix is the source of truth for implemented board support and physical
validation status. Detailed NAND internals live in [NAND](NAND.md).

| Status | Meaning |
|---|---|
| **Ready** | implemented and backed by current board/runtime evidence |
| **Validation** | implemented; the listed real-board proof is still missing |
| **Profile** | PL/profile framework exists; a matching bitstream/DT overlay owns the feature |
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
| AtlANTian NAND install/boot, 1 GiB board | **Validation** | shared software path; dedicated cold NAND boot still required |
| real NAND bad-block case | **Validation** | software is bad-block aware; physical bad-block placement still untested |
| adopted-SD extroot/fallback | **Validation** | implemented; paired-card activation/no-card fallback still needs bench proof |
| interrupted recovery / factory restore | **Validation** | implemented safety/recovery paths still need controlled destructive tests |
| SD/NAND boot jumper | External | BootROM source selected physically |
| Gigabit Ethernet | Ready | GEM/MACB, RGMII-ID, PHY address 1, DHCP |
| UART1 / J12 | Ready | `ttyPS0`, 115200 8N1 |
| D2/D3 LEDs | Ready | Linux LED class |
| S1/S2 buttons | Ready | Linux input; no destructive default action |
| buzzer / J1-J9 enables | Ready | named GPIO lines; high-Z until claimed |
| XADC | Ready | IIO + hwmon |
| Zynq watchdog | Ready | `/dev/watchdog0`; no automatic U-Boot arming |
| FPGA DevCfg/PCAP | Ready | FPGA Manager/Region + configfs overlays |
| D5-D8 | Profile | shipped `status-leds` bitstream/DT overlay |
| six fan headers | Profile | shared PWM + six tach inputs; matching PL design required |
| nine hashboard headers | Profile | profile-specific PL interfaces |
| header I2C/SPI/PL UART | Profile | matching PL design + verified pin ownership required |
| PS USB0 | Disabled | known MIO28-39 collision with hashboard enables/D3 |
| RTC | Not fitted | use network time after cold boot |
| JTAG / 12 V power | External | recovery/power facilities |

## Boot and memory

U-Boot probes a 1 GiB maximum DDR aperture and updates the DT memory node with the
detected bank size. Observed Linux usable memory is roughly 473 MiB on 512 MiB
boards and 970–980 MiB on 1 GiB boards after reservations.

Production SD chain:

```text
BootROM -> SPL BOOT.bin -> u-boot.img -> boot.scr -> uImage + DTB -> ext4 root
```

Persistent U-Boot environment storage is disabled (`ENV_IS_NOWHERE`) so stale
environment state cannot override the image boot policy.

Physical boot source:

```text
jumper = SD   -> BootROM reads SD first stage
jumper = NAND -> BootROM reads NAND first stage
```

No Linux command or U-Boot environment substitutes for moving the jumper.

## NAND evidence summary

Observed stock NAND is Micron `MT29F2G08ABAEAWP`, 256 MiB, with 2048-byte pages,
64-byte OOB, 128 KiB eraseblocks and Micron on-die BCH 4/512 ECC.

The validated 512 MiB-board NAND path includes:

- raw+OOB pre-install backup;
- raw boot programming and final compare from SD U-Boot;
- physical jumper handoff;
- BootROM NAND start and dedicated SPL reader;
- NAND U-Boot and kernel/initramfs/DTB loads;
- UBI/ubiblock/SquashFS/UBIFS/OverlayFS root;
- multi-user Debian, Ethernet/SSH and FPGA userspace startup.

The exact ECC contract, raw offsets, SPL behavior, UBI layout and recovery rules
are intentionally not duplicated here; see [NAND](NAND.md).

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
- Suspend/hibernate is not advertised as recoverable.
- PS USB0 stays disabled because its known route collides with MIO28-39
  functions.
- A Linux/Zynq driver existing does not prove safe board routing.
- A full FPGA bitstream replaces the current PL design; independent full designs
  cannot simply be stacked.

See [Installation](INSTALLATION.md) and [SD Quick Start](QUICKSTART.md) for
operator procedures.
