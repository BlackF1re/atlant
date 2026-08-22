# Hardware validation plan

This checklist separates software contracts, which CI can verify, from claims
that require physical evidence on an Antminer S9 control board. Record the board
variant, image version, boot log and a concise pass/fail result for every completed
item.

## Completed baseline: both RAM variants

The established source-built SD and NAND boot paths are validated on both 512 MiB
and 1 GiB RAM boards. Retain equivalent evidence whenever low-level changes
require a new bench record.

- [x] Identify the board revision, RAM size and NAND ID.
- [x] Cold boot and reboot a source-built SD image.
- [x] Confirm UART through userspace login.
- [x] Confirm Ethernet/DHCP and package-network access.
- [x] Preserve a verified raw+OOB factory NAND backup before destructive NAND work.
- [x] Run `atlantian-nand-install` and retain its complete log.
- [x] Perform cold NAND boot and warm reboot.
- [x] Confirm writable OverlayFS state, Ethernet/SSH and normal multi-user boot.
- [x] Verify the recovery-SD handoff and a same-major NAND rebase.

## Transactional SD FIT validation

The current software/build contract uses A/B kernel+DT FIT slots and is validated
by CI for image layout, FIT hashes, boot-script fallback paths and package staging
order. The following **physical** checks remain before the new transaction can be
called bench-proven:

- [ ] Cold boot a current factory image from FIT slot A on both 512 MiB and 1 GiB
  boards.
- [ ] Switch the active marker to B and prove that the identical B FIT boots.
- [ ] Corrupt the selected FIT deliberately and verify automatic boot from the
  other complete slot.
- [ ] Upgrade a historical `uImage + devicetree.dtb` installation and verify the
  one-time migration fallback plus subsequent normal A/B slot transaction.
- [ ] Interrupt power while writing the **inactive** FIT before the marker switch;
  verify that the old selected slot still boots.
- [ ] Interrupt power after the marker switch; verify that the new slot boots or
  the complete previous slot is reachable through automatic fallback.

The early SD `BOOT.bin`/`u-boot.img` are intentionally excluded from online A/B
updates, so these tests exercise the transaction boundary that AtlANTian actually
claims rather than assuming the BootROM/SPL chain is redundant.

## Remaining NAND/recovery validation

These paths are implemented or bounded by the current software but still require
specific physical proof before being promoted to fully validated behavior:

- [ ] Exercise at least one real factory-bad-block placement through install,
  raw-boot programming and UBI creation.
- [ ] Adopt the paired recovery SD as external upper and verify that it becomes
  active after reboot.
- [ ] Remove the adopted card and verify clean fallback to the independent
  internal UBIFS upper; reinsert it and verify token-authorized activation.
- [ ] Interrupt NAND installation/update at controlled phases and verify the
  documented resume/refusal behavior without ambiguous partial state.
- [ ] Perform controlled power-loss tests at defined safe/unsafe transaction
  points and record the resulting recovery procedure.
- [ ] Validate a deliberate factory raw+OOB restore procedure on sacrificial
  hardware. The repository currently provides backup artifacts, not a generic
  one-command restore tool.

## Recurring validation after low-level changes

Run this focused bench check when changing boot firmware, kernel board support,
NAND tooling, FPGA routes or power policy:

1. SD cold boot and reboot.
2. UART output at `115200 8N1` through userspace login.
3. Ethernet/DHCP and package-network access.
4. For kernel/DT/SD boot changes: boot both FIT slots and exercise fallback before
   recording the transactional SD path as physically validated.
5. Boot-mode and storage status from `atlantian-storage status`.
6. For NAND-related changes: verify the factory backup path, installer/update
   transaction and cold boot from NAND.
7. For FPGA/pin changes: verify voltage, idle state, ownership/conflicts and the
   exact bitstream/DT overlay pair on the target connector.

An automatically accepted stable U-Boot candidate still requires this recurring
low-level bench check before its physical behavior is considered newly proven.
Automatic source tracking and successful SD/NAND/SPL builds are strong software
gates, not substitutes for BootROM/SPL evidence.

Do not promote a hardware status based solely on a successful CI build. CI
validates source and artifact contracts; the bench record validates the board.
