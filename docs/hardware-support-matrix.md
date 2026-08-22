# Hardware support matrix: Bitmain Antminer S9 control board

This document separates **current AtlANTian support** from hardware-expansion
ideas. A Zynq peripheral, Linux driver or theoretically usable FPGA route is not a
supported board interface until its PCB route, voltage, ownership and physical
behavior are proved.

Detailed NAND internals live in [NAND](NAND.md); required real-board tests live in
[Hardware validation](HARDWARE-VALIDATION.md).

## Status rules

| Status | Meaning |
|---|---|
| **Ready** | implemented and backed by current board/runtime evidence |
| **Validation** | implemented; listed physical proof is still missing |
| **Profile** | a specific versioned FPGA bitstream/DT-overlay profile exists for the feature; it is not part of the neutral base PL state |
| **Candidate** | practical extension with a defined implementation path but no current supported implementation |
| **Investigate** | route, voltage or ownership is not proved on this PCB |
| **External** | physical function outside normal Linux peripheral control |
| **Not fitted** | device is not populated on known boards |
| **Unavailable** | blocked by a known collision or absence of a documented usable route |

Before changing a **Profile**, **Candidate** or **Investigate** item, record the
connector, net, voltage, direction, pulls, boot-time state and competing owner.
Keep power, fan, hashboard and boot lines high-impedance until a deliberate profile
claims them.

# Current board support

## Compute, boot and storage

| Capability | Status | Linux interface / evidence | Boundary / next check |
|---|---|---|---|
| XC7Z010 PS: two Cortex-A9 cores | Ready | ARM/Zynq SMP | normal Debian services and native applications |
| NEON and hardware floating point | Ready | ARMv7 `armhf` userspace | do not require a newer CPU ISA |
| 512 MiB and 1 GiB DDR3 | Ready | U-Boot runtime probe, HIGHMEM, no fixed Linux `mem=` cap | retain both sizes in release/bench coverage |
| source-built SD first stage | Ready | exact accepted U-Boot commit, SPL + `u-boot.img`; cold boot/reboot proven on both RAM sizes | stable U-Boot candidates are software-gated automatically; low-level physical validation remains required |
| microSD boot and root | Ready | FAT BOOT + ext4 ROOT, first-boot expansion | large-card/endurance behavior is ordinary media-dependent storage |
| transactional SD kernel/DT | Validation | A/B SHA-256 FIT slots inside existing BOOT; inactive write/verify/sync before marker switch; CI validates layout and fallback script | bench both slots, fallback, historical migration and controlled power-loss points |
| 256 MiB Micron NAND visibility | Ready | PL35X MTD; verified raw+OOB backup path | preserve backup before destructive operations |
| AtlANTian NAND install/boot, 512 MiB | Ready | destructive install and cold/warm boot through OverlayFS proven | regression-test low-level changes |
| AtlANTian NAND install/boot, 1 GiB | Ready | destructive install and cold/warm boot through OverlayFS proven | regression-test low-level changes |
| NAND bad-block handling | Validation | software is bad-block aware | exercise real factory-bad-block placement |
| interrupted/power-loss NAND recovery | Validation | resume/refusal paths exist | controlled destructive bench tests |
| adopted-SD extroot and no-card fallback | Validation | implemented with paired-card token | validate activation/fallback on hardware |
| SD/NAND boot jumper | External | BootROM source is selected physically | operator must move the jumper when instructed |
| persistent U-Boot environment | Unavailable | intentionally `ENV_IS_NOWHERE` | change only with an atomic recoverable design |
| QSPI / parallel NOR storage | Unavailable | no usable device/route documented on the supported board | hardware redesign or new routing proof required |

## Board I/O and management

| Capability | Status | Linux interface / evidence | Boundary / next check |
|---|---|---|---|
| Gigabit Ethernet | Ready | GEM0/MACB, RGMII-ID, PHY address 1, DHCP | primary supported network interface |
| UART1 on J12 | Ready | `ttyPS0`, `115200 8N1` | 3.3 V logic only |
| D2 / D3 LEDs | Ready | Linux LED class | D3 colors remain available for state semantics |
| S1 / S2 buttons | Ready | Linux input; no destructive default action | destructive actions must remain explicit |
| buzzer GPIO exposure | Ready | named GPIO line, unclaimed by default | alert behavior belongs to an explicit policy/profile |
| J1-J9 hashboard-enable GPIO exposure | Ready | named GPIO lines; input/high-Z until deliberately claimed | **not** a claim that hashboard power sequencing is implemented |
| XADC die sensors | Ready | IIO + hwmon | use stable documented labels |
| Zynq watchdog | Ready | `/dev/watchdog0`; no automatic U-Boot arming | default recovery policy remains conservative |
| RTC / battery-backed time | Not fitted | cold boot requires network/manual time | external RTC requires a verified adapter/profile |
| JTAG | External | development/recovery facility | use correct board voltage reference |
| 12 V input and onboard power stages | External | no generic Linux power-disconnect contract | `poweroff` cannot remove input power |

## FPGA support shipped by the base system

| Capability | Status | Interface / evidence | Boundary |
|---|---|---|---|
| FPGA DevCfg/PCAP programming | Ready | FPGA Manager/Region + configfs overlays | full bitstream replaces the active PL design |
| D5-D8 status LEDs | Profile | shipped `status-leds` bitstream + DT overlay | polarity/pins belong to that profile |
| FPGA profile userspace lifecycle | Ready | `atlantian-fpga status/apply/remove` | overlay and bitstream must describe the same design |

## Pin reference and non-negotiable boundaries

| Signal | Mapping | Note |
|---|---|---|
| D2 | MIO15 | active-low |
| D3 red | MIO37 | active-high |
| D3 green | MIO38 | active-high |
| S1 | MIO47 | active-low |
| S2 | MIO51 | active-low |
| buzzer | MIO39 | unclaimed by default |
| J1-J9 enables | MIO28-MIO36 | input/high-Z until claimed |
| D5 | PL M19 / AXI GPIO bit 2 | Bank 35, 3.3 V, active-low |
| D6 | PL M17 / AXI GPIO bit 3 | Bank 35, 3.3 V, active-low |
| D7 | PL F16 / AXI GPIO bit 0 | Bank 35, 3.3 V, active-low |
| D8 | PL L19 / AXI GPIO bit 1 | Bank 35, 3.3 V, active-low |
| fan PWM | PL J18 | shared across six headers |
| fan tach 1-6 | PL F19/F20/G17/G18/J20/H20 | independent inputs |

- `poweroff` halts Linux but cannot remove external 12 V.
- Suspend and hibernate are not advertised as recoverable.
- PS USB0 is unavailable because its known MIO route conflicts with board
  functions.
- A full FPGA bitstream replaces the current PL design; independent full designs
  cannot be stacked.
- Reusing a MIO pin requires changing its mux. Never claim a pin merely because
  the Zynq manual lists an alternate function.

## Boot and NAND evidence

U-Boot probes a 1 GiB maximum DDR aperture and updates the DT memory node with the
detected bank size. Observed Linux usable memory is roughly 473 MiB on 512 MiB
boards and 970-980 MiB on 1 GiB boards after reservations.

Current production SD chain:

```text
BootROM -> SPL BOOT.bin -> u-boot.img -> boot.scr
                                      -> active atlantian-{A|B}.itb (kernel + DTB)
                                      -> fallback FIT slot if needed
                                      -> ext4 root
```

Historical releases used `boot.scr -> uImage + devicetree.dtb`. The first update
to the current layout retains that old payload as a one-generation migration
fallback only after both new FIT slots have already been written.

The early SD first-stage files are not replaced by online platform updates.
Fresh factory images use the accepted U-Boot source pin; NAND updates replace
their release-matched raw boot payload through the paired recovery-SD transaction.
The A/B FIT implementation is current source policy but remains `Validation`
until the controlled physical checks in [Hardware validation](HARDWARE-VALIDATION.md)
are recorded.

Physical boot selection:

```text
jumper = SD   -> BootROM reads SD first stage
jumper = NAND -> BootROM reads NAND first stage
```

Observed stock NAND is Micron `MT29F2G08ABAEAWP`, 256 MiB, with 2048-byte pages,
64-byte OOB, 128 KiB eraseblocks and Micron on-die BCH 4/512 ECC. Exact ECC,
raw offsets, SPL behavior, UBI layout and recovery rules belong to
[NAND](NAND.md).

# Expansion and investigation roadmap

Everything below is **not base-system support** unless its status later moves to
Ready or a documented shipped Profile. These entries exist to record safe paths
for future hardware work without confusing SoC capability with PCB capability.

## FPGA and connector expansion

| Capability | Status | Required work before support |
|---|---|---|
| AXI control/register blocks | Candidate | define register map, reset, error handling and DT binding |
| AXI DMA / streaming data | Candidate | define buffer ownership, benchmark DDR pressure and bound failure cases |
| PL interrupts | Candidate | define interrupt ownership/names and recovery behavior |
| six fan headers | Candidate | build a versioned PL profile, then add RPM plausibility, stall alarms and fail-safe PWM policy |
| nine hashboard headers | Candidate | define electrical/protocol contract and deliberate power-sequencing profile |
| Header I2C | Candidate | implement a profile with verified pin ownership, open-drain behavior, bus recovery and DT devices |
| Header SPI | Candidate | implement a profile with verified voltage/pins, chip-select ownership and maximum clock |
| Header UART | Candidate | implement a profile with verified voltage/pins and console exclusion rules |
| Header GPIO / interrupts | Candidate | pin/voltage proof and input-safe defaults |
| PWM/capture/tachometry in PL | Candidate | electrical proof plus defined timer/counter interface |
| Additional PS buses through EMIO | Candidate | matching PL route, external electrical interface and DT overlay |
| CAN | Candidate | verified route plus external transceiver, termination and bus-off testing |
| Custom protocol engine / coprocessor | Candidate | resource/clock/reset budget and observable failure handling |
| FPGA partial reconfiguration | Investigate | isolation, compatibility, rollback and boot recovery proof |
| PCIe, HDMI/display, camera or RF high-speed links | Unavailable | no documented board connector/routing; treat as carrier-board work |

## Processing-system peripherals without proven board routes

| PS capability | Status | What must be proved |
|---|---|---|
| Ethernet GEM1 | Investigate | PHY plus RGMII/MII/PL route, or a separate PL Ethernet design |
| USB0 | Unavailable | MIO28-39 collision with hashboard enables, D3 and buzzer blocks this route |
| USB1 | Investigate | external PHY/connector route; otherwise use purpose-built expansion hardware |
| SD/SDIO1 | Investigate | routed socket/eMMC or a verified EMIO/PL implementation |
| UART0 | Investigate | MIO/connector ownership or a PL UART adapter |
| I2C0/I2C1 | Investigate | MIO ownership or EMIO/PL route plus voltage-safe device interface |
| SPI0/SPI1 | Investigate | MIO ownership or EMIO/PL route plus signal/chip-select definition |
| CAN0/CAN1 | Investigate | verified route and external CAN transceiver |
| unassigned PS GPIO | Investigate | trace MIO16-27 before mux/GPIO use |
| XADC external analogue channels | Candidate | prove routing, input range and calibration |
| Ethernet PTP/timestamping | Candidate | validate with a PTP-capable peer before advertising accuracy |
| power/current telemetry | Investigate | identify a real telemetry IC/sense route or add an external monitor |
| additional thermal sensors | Investigate | identify bus/device/calibration before creating hwmon names |

## Software boundary

| Capability | Status | Policy |
|---|---|---|
| Debian-compatible `armhf` userspace | Ready | `ID=debian`; factory Snapshot is pinned while runtime APT follows live installed codename |
| custom Linux board kernel | Ready | exact stable LTS commit per release; automatic patch tracking never changes the selected LTS series |
| systemd, SSH and standard network tooling | Ready | normal Debian service model |
| IPv4/IPv6, DHCP and static Ethernet configuration | Ready | use supported GEM0 network interface |
| Linux DT and configfs overlays | Ready | board DTB plus FPGA profile overlays |
| GPIO, LEDs, buttons and buzzer APIs | Ready | libgpiod, LED class and input subsystem; destructive actions stay opt-in |
| NAND MTD/UBI/SquashFS/UBIFS/OverlayFS | Ready | flash-aware immutable lower + writable upper |
| NAND installer + verified factory backup | Ready | backup and installation are implemented and bench-proven |
| factory raw+OOB restore procedure | Validation | controlled physical restore still requires dedicated validation |
| FPGA peripherals beyond shipped status LEDs | Candidate | become Profile only when a concrete compatible bitstream/DT-overlay pair exists |
| Wi-Fi, Bluetooth, cellular or USB peripherals | Candidate | require a genuinely supported external transport/adapter; PS USB routing is not currently supported |

The matrix deliberately avoids listing generic Debian applications as hardware
features. If software can simply be installed with APT and needs no AtlANTian
board integration, it does not need a separate support status here.
