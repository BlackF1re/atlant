# Contributing

Prefer narrow changes, explicit evidence and a regression test/contract for every
bug fixed. Start with the topic index in [docs/README.md](docs/README.md).

## Change rules

| Area | Requirement |
|---|---|
| Debian lifecycle | keep immutable factory Snapshot and live runtime APT separate; never skip majors |
| DT/kernel | preserve boot-critical interfaces and verified pin safety |
| FPGA profile | document bitstream, DT overlay, pins, voltage and conflicts |
| persistence/update | preserve documented user/application state; package state must follow the active base |
| release tooling | fail closed on validation errors while treating same-source GitHub release state idempotently |
| GitHub Actions | use allow-listed official Actions pinned to immutable 40-hex commits |

Passwordless root on a fresh image is deliberate first-provisioning policy; do not
silently change it as a generic hardening cleanup.

## Checks

Run the relevant fast checks before pushing. The normal CI baseline is:

```sh
python3 .github/scripts/validate-automation.py
python3 .github/scripts/actions-policy.py scan .github/workflows
python3 .github/scripts/check-doc-links.py
bash scripts/test-build-orchestration.sh
bash scripts/test-runtime-policy.sh
bash scripts/test-release-versioning.sh
bash scripts/test-source-contracts.sh
bash scripts/test-update-leds.sh
```

Release/download-metric changes should also run:

```sh
bash scripts/test-release-metrics.sh
```

Complete build:

```sh
sudo bash scripts/bootstrap-host.sh
sudo -E bash scripts/build-incremental.sh all
```

Repository scripts are invoked through explicit interpreters so source archives
remain usable even if executable mode bits are lost while downloading and
re-uploading files.

Production CI additionally runs the release-upgrade gate and the clean NAND
OverlayFS rebase integration test. Local opt-in is available through
`ATLANTIAN_RELEASE_UPGRADE_TEST=true` and `ATLANTIAN_NAND_REBASE_TEST=true` when
running `scripts/test-build.sh` against built artifacts.

## Hardware evidence

A hardware claim should state what proves it: schematic/board evidence for routes,
boot log + functional test for peripherals, bitstream/DTBO/pin map for FPGA
profiles, and voltage/conflict analysis plus bench validation for electrical
safety. Do not promote a route from **Profile**, **Candidate** or **Validation** to
**Ready** merely because a Zynq driver exists.

## Repository hygiene

- Use Conventional Commits.
- Do not commit secrets, personal hostnames/addresses or local machine paths.
- Put installation-specific overrides in `config/local.env`.
- Keep documentation in the file that owns the topic and cross-link instead of
  duplicating behavior.
- Treat `config/packages.base` as the userspace source of truth rather than
  maintaining prose package inventories.
- Update owning documentation and tests when behavior changes.

## Pull requests and publication

External contributions use pull requests. PR CI is read-only and validates source,
workflow, Markdown and build contracts. Dependabot Action-pin updates may follow
the repository's restricted trusted automation only when the diff is limited to
allow-listed immutable Action pin replacements; structural workflow changes remain
manual.

Production artifacts are published only from the current `main` tip after the
full gates in [docs/PIPELINE.md](docs/PIPELINE.md) pass. Fresh repositories and
interrupted same-source publication use the idempotent bootstrap/reconciliation
rules documented there.
