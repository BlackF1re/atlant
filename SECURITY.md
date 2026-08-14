# Security policy

## Supported scope

| Layer | Support policy |
|---|---|
| AtlANTian release tooling | newest published release |
| Release upgrade path | each release is validated against the latest eligible published release |
| Debian userspace | follows Debian support for the installed codename |
| Kernel/board support | pinned board kernel until deliberately changed and validated |
| SD boot firmware | pinned upstream U-Boot; low-level changes require board validation |

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
| pinned Linux/U-Boot commits | deterministic upstream source identity |
| release `SHA256SUMS` | integrity of the public downloadable payload |
| version-matched AtlANTian `.deb` set | prevents mixed platform/kernel/release installs |
| GitHub build provenance | ties sealed build outputs to source/workflow/commit |
| release-upgrade gate | blocks invalid package transitions between published releases |

On-device updates download over HTTPS and verify the selected payload against the
published `SHA256SUMS`. Build provenance is generated for the sealed outputs that
enter the publication stage; the board does not currently verify provenance
locally. Publication-only metadata such as `atlantian-update.json` and the public
checksum manifest is generated after sealing and is validated by the publication
contracts rather than treated as a separately attested build output.

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

- **SD:** explicit `atlantian-sysupgrade` handles supported `N → N+1` transitions.
- **NAND:** same-major base upgrades use the recovery-SD rebase transaction;
  Debian-major changes require a clean NAND reinstall and deliberate transfer of
  selected application/user state.

See [Upgrading](docs/UPGRADING.md).

## Hardware validation boundary

CI validates source pins, artifacts and software contracts but cannot prove
physical BootROM/SPL execution, real NAND ECC/bad blocks, FPGA routing or
electrical behavior. Low-level boot/kernel changes therefore remain deliberate
hardware-validation events; unverified/conflicting routes stay disabled or
profile-only.

See [Hardware support](docs/hardware-support-matrix.md) and
[release pipeline](docs/PIPELINE.md).
