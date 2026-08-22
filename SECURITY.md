# Security policy

## Supported scope

| Layer | Support policy |
|---|---|
| AtlANTian release tooling | newest published release |
| Release upgrade path | each release is validated against the latest eligible published release |
| Debian userspace | follows Debian support for the installed codename through live APT repositories |
| Kernel/board support | selected Linux LTS series; accepted stable patch commit is pinned per release |
| SD boot firmware | accepted stable upstream U-Boot commit; low-level changes require board validation |

## Reporting a vulnerability

Do **not** publish an unpatched vulnerability in a public issue or discussion.

If the repository Security page offers GitHub's private **Report a vulnerability**
form, use it. Otherwise contact the maintainer privately through the contact link
published on the [BlackF1re GitHub profile](https://github.com/BlackF1re).
Include the affected release, reproduction, impact/required access and any known
mitigation. Do not send credentials or unrelated private data.

## Release trust model

| Control | Purpose |
|---|---|
| immutable Debian Snapshot metadata | reproducible factory package baseline |
| selected Linux LTS series + exact commit | deterministic board-kernel source identity; no movable tag is resolved during a release build |
| stable U-Boot tag discovery + exact commit | automation may discover a stable candidate, but production consumes an immutable source SHA |
| candidate kernel/U-Boot gates | kernel config/board contract and both SD + NAND/SPL U-Boot builds must validate before automatic upstream input merge |
| release `SHA256SUMS` | integrity of the public downloadable payload |
| version-matched AtlANTian `.deb` set | prevents mixed platform/kernel/release installs |
| transactional SD A/B FIT | kernel and matching DTB are one SHA-256 FIT; inactive slot is written/verified before the active marker changes |
| GitHub build provenance | ties sealed build outputs to source/workflow/commit |
| release-upgrade gate | blocks invalid package transitions between published releases |

On-device platform updates download over HTTPS and verify the selected payload
against the published `SHA256SUMS`. Build provenance is generated for the sealed
outputs that enter the publication stage; the board does not currently verify
provenance locally. Publication-only metadata such as `atlantian-update.json` and
the public checksum manifest is generated after sealing and is validated by the
publication contracts rather than treated as a separately attested build output.

Factory-input reproducibility and runtime security maintenance are intentionally
separate. Factory images use an exact Debian Snapshot; installed systems use live
repositories for their fixed Debian codename, so normal `apt upgrade` security
maintenance does not wait for a new AtlANTian image. The custom AtlANTian kernel,
DT and platform policy remain release-controlled because they are validated as a
board-specific set.

## SD boot update boundary

The normal SD platform update does **not** rewrite the early `BOOT.bin` or
`u-boot.img` on the live FAT partition. Those files execute before the kernel-slot
transaction can provide redundancy; replacing them in place would create a real
power-loss window. Fresh complete images carry the current accepted U-Boot.

Kernel and DTB updates use two FIT slots within the existing BOOT partition. The
new FIT is staged into the inactive slot, byte-verified and synced before the tiny
active-slot marker is changed. U-Boot tries the other complete slot if the selected
FIT fails. A future incompatible boot-loader ABI change fails closed and requires
a reflash rather than weakening this model.

NAND boot firmware is updated differently: same-major NAND maintenance is staged
and verified through the paired recovery SD before the target raw boot region is
programmed/read-back-verified.

## Initial root access

Passwordless root access on a fresh image is intentional first-provisioning
policy. No shared SSH host private key is embedded. Each flash generates a
machine ID and host keys; an interactive root shell warns until authentication
is configured.

Keep first provisioning on a trusted network, then set either:

```sh
passwd
```

or a root SSH public key.

## Debian repositories and major changes

Factory builds use immutable Snapshot metadata. Running systems use live HTTPS
repositories pinned to the installed Debian codename; moving `stable` is never
used on-device.

APT repository indexes are disposable and bounded to a 96 MiB tmpfs. Downloaded
package archives use storage-backed APT staging and are configured not to be kept
after installation; large package transactions therefore do not depend on a
tmpfs sized to a fixed fraction of system RAM.

- **SD:** explicit `atlantian-sysupgrade` handles supported AtlANTian platform
  releases and staged `N → N+1` Debian transitions.
- **NAND:** same-major base upgrades use the recovery-SD rebase transaction;
  Debian-major changes require a clean NAND reinstall and deliberate transfer of
  selected application/user state.

See [Upgrading](docs/UPGRADING.md).

## Hardware validation boundary

CI validates source pins, candidate kernel/U-Boot software contracts, artifacts
and update transactions, but cannot prove physical BootROM/SPL execution, real
NAND ECC/bad blocks, FPGA routing or electrical behavior. An automatically
accepted U-Boot stable source still remains a low-level hardware change until it
has been exercised on the board. Unverified/conflicting routes stay disabled or
profile-only.

See [Hardware support](docs/hardware-support-matrix.md) and
[release pipeline](docs/PIPELINE.md).
