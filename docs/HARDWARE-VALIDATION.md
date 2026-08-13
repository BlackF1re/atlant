# Hardware validation plan

This checklist separates software contracts, which CI can verify, from claims
that require physical evidence on an Antminer S9 control board. Record the
board variant, image version, boot log and a concise pass/fail result for every
completed item.

## Completed: NAND boot on 1 GiB boards

The NAND install and boot path is validated on both 512 MiB and 1 GiB RAM
boards. Retain the following evidence whenever low-level changes require a new
bench record.

- [x] Identify the board revision, RAM size and NAND ID.
- [x] Boot the current SD image and preserve a raw+OOB factory NAND backup.
- [x] Run `atlantian-nand-install` and retain its complete log.
- [x] Perform cold NAND boots and a warm reboot.
- [x] Confirm Ethernet/DHCP, writable OverlayFS state and kernel boot logs.
- [x] Verify the recovery-SD handoff and a same-major NAND rebase.

## Recurring validation after low-level changes

Run this focused bench check when changing boot firmware, kernel board support,
NAND tooling, FPGA routes or power policy:

1. SD cold boot and reboot.
2. UART output at `115200 8N1` through userspace login.
3. Ethernet/DHCP and package-network access.
4. Boot-mode and storage status from `atlantian-storage status`.
5. Only for NAND-related changes: factory backup, installer verification and
   a cold boot from NAND.

Do not promote a hardware status based solely on a successful CI build. CI
validates source and artifact contracts; the bench record validates the board.
