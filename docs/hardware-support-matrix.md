# Hardware and software capability matrix: Bitmain Antminer S9 control board

This is the planning catalogue for AtlANTian support. It separates what is
working on the board from Zynq capabilities that can be added through the PL
or must first be proved on the physical PCB. A Linux driver or a Zynq feature
alone is **not** a promise that it is safe to enable on this board.

Detailed NAND internals live in [NAND](NAND.md); real-board test cases live in
[Hardware validation](HARDWARE-VALIDATION.md).

## Status and planning rules

| Status | Meaning |
|---|---|
| **Ready** | implemented and backed by current board/runtime evidence |
| **Validation** | implemented; the listed real-board proof is still missing |
| **Profile** | a PL/profile framework exists; a bitstream and DT overlay own the feature |
| **Candidate** | technically practical addition; it needs a defined PL design or a small board adapter |
| **Investigate** | the Zynq can provide it, but this board's route, voltage and ownership are unproved |
| **External** | physical function outside Linux peripheral control |
| **Not fitted** | device is not populated on the known board |
| **Unavailable** | blocked by a known collision or by the absence of a documented board route |

Before changing any **Candidate** or **Investigate** item, record the connector,
net, voltage level, direction, pull resistors, boot-time state and competing
owner. Keep power, fan, hashboard and boot lines high-impedance until their
profile deliberately claims them.

## Board baseline: compute, boot and storage

| Capability | Status | Linux interface / evidence | Next support step |
|---|---|---|---|
| XC7Z010 PS: two Cortex-A9 cores | Ready | ARM/Zynq SMP | normal Debian services and native applications |
| NEON and hardware floating point | Ready | ARMv7 userspace | build `armhf` packages with an appropriate baseline; do not require a newer CPU ISA |
| 512 MiB and 1 GiB DDR3 | Ready | U-Boot runtime probe, HIGHMEM, no fixed Linux `mem=` cap | keep both sizes in the release test matrix |
| 256 KiB on-chip memory | Candidate | Zynq PS resource | reserve only for a measured low-latency/early-boot use case |
| source-built SD first stage | Ready | pinned U-Boot SPL + `u-boot.img`; cold boot/reboot proven on both RAM sizes | retain as the default recovery path |
| microSD boot and root | Ready | FAT `BOOT` + ext4 `ROOT`, first-boot expansion | add endurance/large-card checks when hardware is available |
| SD write-protect and card-detect signals | Candidate | SDIO0 pins are assigned by the board | expose only after confirming the actual socket wiring and desired UX |
| 256 MiB Micron NAND visibility | Ready | PL35X MTD; raw+OOB backup path | preserve raw backup before destructive operations |
| AtlANTian NAND install and boot, 512 MiB | Ready | destructive install and cold BootROM -> SPL -> U-Boot -> Linux -> OverlayFS boot proven | regression-test with releases |
| AtlANTian NAND install and boot, 1 GiB | Ready | destructive install, cold NAND boot, warm reboot and OverlayFS proven | regression-test with releases |
| NAND bad-block placement | Validation | software is bad-block aware | exercise a real bad-block layout and document the result |
| NAND recovery interrupted during install | Validation | recovery paths exist | run controlled destructive/power-loss tests |
| adopted-SD extroot and no-card fallback | Validation | implemented | validate paired-card activation and fallback on a bench board |
| SD/NAND boot jumper | External | BootROM source is selected physically | keep operator instructions explicit |
| QSPI boot/storage | Unavailable | no QSPI flash device or board route is documented | requires hardware redesign or a verified unpopulated footprint |
| parallel NOR/SRAM storage | Unavailable | no device or board route is documented | requires hardware redesign |
| persistent U-Boot environment | Unavailable | intentionally `ENV_IS_NOWHERE` | retain this policy unless an atomic, recoverable storage design is specified |

## Board I/O and management

| Capability | Status | Linux interface / evidence | Next support step |
|---|---|---|---|
| Gigabit Ethernet | Ready | GEM0/MACB, RGMII-ID, PHY address 1, DHCP | keep IPv4, IPv6 and static-address documentation current |
| Ethernet hardware timestamping / PTP | Candidate | GEM hardware supports timestamping; board uses GEM0 | validate with a PTP-capable peer before advertising timing accuracy |
| UART1 on J12 | Ready | `ttyPS0`, 115200 8N1 | console, recovery and serial automation |
| UART0 | Investigate | second PS UART exists, but no board route is documented | trace MIO/connector ownership; otherwise use a PL UART adapter |
| D2 / D3 LEDs | Ready | Linux LED class | reserve D3 colors for health/state semantics |
| S1 / S2 buttons | Ready | Linux input; no destructive default action | add deliberate, documented long-press actions only if needed |
| buzzer | Ready | named GPIO line, unclaimed by default | add rate-limited alert patterns in a board-management profile |
| J1-J9 hashboard enables | Ready | named GPIO lines, inputs/high-Z until claimed | claim only in a hashboard power-sequencing profile |
| XADC die sensors | Ready | IIO + hwmon | retain stable, documented hwmon labels |
| XADC external analogue channels | Candidate | XADC can expose them through IIO after routing is proved | calibrate and label each proven channel |
| Zynq watchdog | Ready | `/dev/watchdog0`; no automatic U-Boot arming | enable a service watchdog only with a tested recovery policy |
| RTC / battery-backed time | Not fitted | network time is required after a cold boot | add an external I2C/PL RTC only with a verified adapter |
| JTAG | External | recovery/development facility | document a safe adapter and voltage reference before routine use |
| 12 V input and onboard power stages | External | no generic Linux power-control contract | never present `poweroff` as removal of input power |
| Power, voltage and current telemetry | Investigate | no documented telemetry IC or calibrated sense route | trace the board; otherwise add an isolated external monitor |
| Thermal sensors beyond XADC sources | Investigate | no complete sensor inventory is documented | identify sensor buses and calibration before exposing hwmon names |

## FPGA and connector expansion

| Capability | Status | Linux interface / evidence | Next support step |
|---|---|---|---|
| FPGA DevCfg/PCAP programming | Ready | FPGA Manager, Region and configfs overlays | version bitstream and DT overlay as one profile artifact |
| AXI control and data paths between PS and PL | Candidate | Zynq PS/PL AXI interfaces are available | define register map, DMA ownership, reset and error handling per IP |
| PL interrupts to Linux | Candidate | Zynq PS/PL interrupt fabric | include interrupt names and a recovery path in the overlay |
| AXI GPIO / register blocks | Candidate | standard FPGA + kernel framework | preferred basis for small board-control profiles |
| AXI DMA / streaming data plane | Candidate | Zynq PS/PL memory interfaces | benchmark DDR pressure and bound DMA buffers before production use |
| D5-D8 LEDs | Profile | shipped `status-leds` bitstream/DT overlay | keep their polarity and ownership in the profile |
| six fan headers | Profile | shared PWM plus six tach inputs; matching PL design required | implement RPM plausibility, stall alarms and fail-safe PWM policy |
| nine hashboard headers | Profile | profile-specific PL interfaces | publish an electrical/protocol contract before enabling any ASIC workload |
| Header I2C | Profile | matching PL design and verified pin ownership required | use open-drain buffers, bus recovery and per-device DT nodes |
| Header SPI | Profile | matching PL design and verified pin ownership required | document chip-select, level and maximum clock per target |
| Header UART | Profile | matching PL design and verified pin ownership required | define voltage, connector and console exclusion rules |
| Header GPIO / interrupts | Candidate | realizable in PL after pin/voltage verification | prefer input-safe defaults and named GPIO lines |
| PWM, capture and tachometry in PL | Candidate | existing fan profile establishes the pattern | reuse for pumps, fans or external timing only after electrical checks |
| Additional serial buses through EMIO | Candidate | PS GPIO, I2C, SPI, UART and CAN can be routed via PL | use when the physical connector is PL-connected; supply a bitstream plus DT overlay |
| CAN bus | Candidate | two PS CAN controllers; external transceiver required | route through PL/adapter, provide termination and test bus-off recovery |
| GPIO expanders / sensors on external adapters | Candidate | I2C/SPI through a verified PL profile | choose a stable connector pinout and upstream kernel bindings |
| Custom protocol engine / coprocessor | Candidate | XC7Z010 PL has logic, BRAM and DSP resources | budget LUT/BRAM/DSP, clock domains and observability first |
| FPGA partial reconfiguration | Investigate | not part of the current profile contract | prove isolation, rollback and boot recovery before considering it |
| PCIe, HDMI/display, camera or RF high-speed links | Unavailable | no documented board connector/routing supports them | treat as a new carrier-board design, not a software feature |

## PS peripheral inventory: do not enable without routing proof

The following are genuine Zynq-7010 processing-system capabilities, but are not
currently established as board interfaces. They are listed so they are not
overlooked during hardware exploration; their status is intentionally not
"Ready".

| PS capability | Board status | Practical route to support |
|---|---|---|
| second Gigabit Ethernet MAC (GEM1) | Investigate | prove a PHY and RGMII/MII/PL route, or use a PL Ethernet design with a suitable external PHY |
| USB0 | Unavailable | MIO28-39 collides with hashboard enables, D3 and buzzer; do not mux it on this board |
| USB1 | Investigate | requires proof of its external PHY/connector route; otherwise use a purpose-built external adapter |
| second SD/SDIO controller | Investigate | requires a routed socket/eMMC or an EMIO/PL design; no device is documented |
| I2C0/I2C1 | Investigate | prove MIO ownership or route through EMIO + PL; use level-safe external devices only |
| SPI0/SPI1 | Investigate | prove MIO ownership or route through EMIO + PL; define signal integrity and chip-select ownership |
| CAN0/CAN1 | Investigate | a CAN transceiver and a verified route are required; PS controller alone is insufficient |
| PS GPIO not assigned to a board function | Investigate | MIO16-27 must be traced before any mux or GPIO use; do not infer a connector from unused pin names |
| TTC timers / fabric clock inputs | Candidate | use for kernel timing/capture after pin and clock-source ownership are defined |
| PS DMA controllers | Candidate | use with a documented kernel driver and bounded buffers; it is not a standalone external I/O |
| crypto boot/configuration features | Investigate | requires a reviewed key-provisioning and recovery process; never enable on a production board as an experiment |

## Software capability catalogue

| Capability | Status | Interface / policy | Next support step |
|---|---|---|---|
| Debian-compatible `armhf` userspace | Ready | `ID=debian`; AtlANTian identity remains in release metadata | keep package sources and snapshot policy reproducible |
| systemd services, SSH and standard network tooling | Ready | normal Debian service model | publish only services that are enabled in the image |
| IPv4/IPv6, DHCP and static Ethernet configuration | Ready | standard Linux networking over GEM0 | add VLAN/bridge profiles only when a use case requires them |
| Linux device tree and overlays | Ready | board DTB plus FPGA Region/configfs overlays | treat bitstream, overlay and userspace as one compatible release unit |
| GPIO, LEDs, buttons and buzzer APIs | Ready | libgpiod, LED class and input subsystem | keep destructive actions opt-in |
| sensor and fan telemetry | Profile | IIO/hwmon plus a matching PL profile | expose calibrated names, limits and alarms |
| watchdog-based service recovery | Candidate | `/dev/watchdog0` | test boot-loop and operator recovery before enabling by default |
| NAND MTD, UBI, SquashFS, UBIFS and OverlayFS | Ready | flash-aware immutable lower + writable upper | retain backup and recovery procedures |
| SD/NAND installer and factory recovery | Ready / Validation | recovery payload ships with the SD image; interruption tests remain pending | complete physical destructive test matrix |
| FPGA profile lifecycle | Candidate | load, validate, activate and roll back profile artifacts | define compatibility metadata and a known-good fallback profile |
| Lightweight containers | Investigate | Debian can install tooling, but memory, storage and watchdog impact are unqualified | qualify one specific runtime before making it a project feature |
| Full virtual machines | Unavailable | no qualified hardware-virtualization, memory or storage budget exists | do not position the board as a VM host |
| Wi-Fi, Bluetooth, cellular and USB storage | Candidate | external network/USB hardware is required; current USB routing is not a supported board interface | prefer Ethernet-connected adapters or a verified PL/expansion design |
| Remote update / fleet management | Candidate | standard signed package/image workflow can be built on the existing release pipeline | specify authentication, rollback and loss-of-network behaviour first |
| Metrics and monitoring | Candidate | standard Debian agents plus board sensor profiles | choose one minimal agent and keep its resource budget explicit |

## Pin reference and non-negotiable boundaries

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

- `poweroff` halts Linux but cannot remove external 12 V.
- Suspend and hibernate are not advertised as recoverable.
- PS USB0 remains unavailable because its known MIO route conflicts with board
  functions.
- A full FPGA bitstream replaces the current PL design; independent full designs
  cannot be stacked.
- Reusing a MIO pin requires changing its mux. Never claim a pin merely because
  the Zynq manual lists an alternate function for it.

## Boot and NAND evidence

U-Boot probes a 1 GiB maximum DDR aperture and updates the DT memory node with
the detected bank size. Observed Linux usable memory is roughly 473 MiB on
512 MiB boards and 970-980 MiB on 1 GiB boards after reservations.

Production SD chain:

```text
BootROM -> SPL BOOT.bin -> u-boot.img -> boot.scr -> uImage + DTB -> ext4 root
```

Physical boot selection:

```text
jumper = SD   -> BootROM reads SD first stage
jumper = NAND -> BootROM reads NAND first stage
```

Observed stock NAND is Micron `MT29F2G08ABAEAWP`, 256 MiB, with 2048-byte pages,
64-byte OOB, 128 KiB eraseblocks and Micron on-die BCH 4/512 ECC. The exact ECC
contract, raw offsets, SPL behaviour, UBI layout and recovery rules are owned by
[NAND](NAND.md), rather than duplicated here.
