# Debian lifecycle

This document owns AtlANTian's Debian-generation and Debian Snapshot policy.
User-facing upgrades are documented in [Upgrading](UPGRADING.md); Linux/U-Boot
tracking, GitHub CI, protected-main merge mechanics and release publication are
documented in [Pipeline](PIPELINE.md).

## Policy

| Rule | Behavior |
|---|---|
| Architecture | configured Debian generation must still publish `armhf` |
| Factory input | exact Debian Snapshot metadata is frozen |
| Runtime repositories | installed codename is fixed; moving `stable` is never used |
| Routine Debian change | refresh and validate the frozen Snapshot; Debian-only factory changes join the normal release batch |
| Linux/U-Boot change in same watcher run | coalesce the newest accepted Debian Snapshot into the same release transaction |
| New Debian major | report availability only; transition remains explicit |
| Failure | keep the last verified Snapshot and configured generation |

A Snapshot refresh changes the reproducible factory package baseline, but it does
**not** delay security/package maintenance on installed boards: runtime APT uses
live repositories for the installed codename. Consequently a Debian-only Snapshot
refresh does not need to publish a full SD/NAND image every day. It contributes to
the normal five-release-input batch. If the same daily upstream transaction also
advances the selected Linux LTS patchlevel or stable U-Boot, the combined inputs
become release-eligible immediately.

The Snapshot timestamp is recorded separately from the AtlANTian semantic version.

## Unified daily watcher

The workflow file remains `.github/workflows/debian-watch.yml` for repository
continuity, but the workflow is named **Upstream Base Watch** and runs daily at
**06:17 Asia/Tomsk**. It also runs when its protected-maintenance/upstream-refresh
plumbing changes so those changes are exercised immediately.

Its Debian half:

1. reads the configured Debian major/codename and verifies `armhf` availability
   in Debian main, updates and security;
2. compares live Debian Release metadata with the frozen checksums;
3. when Debian changed, waits until Debian Snapshot contains those exact metadata
   bytes and freezes the new Snapshot timestamp/checksums;
4. validates the resulting immutable release inputs;
5. combines those files with any accepted Linux/U-Boot candidate from the same
   watcher execution in **one** protected maintenance commit;
6. publishes immediately only when a boot input changed or the combined
   release-input count reached the normal five-commit threshold;
7. separately reports when the immediate next Debian major becomes available.

The watcher never pushes directly to protected `main` and never receives a branch
protection bypass. Exact maintenance-PR, merge-candidate validation, status bridge
and squash-merge mechanics are intentionally documented only in
[Pipeline](PIPELINE.md).

If the runner's `debootstrap` package does not yet know the configured codename,
AtlANTian uses Debian's generic bootstrap script while still targeting the pinned
codename and Snapshot.

> [!IMPORTANT]
> If Debian drops `armhf`, AtlANTian fails closed on the configured generation
> instead of silently moving to an incompatible base.

## Factory baseline vs running system

| Factory image | Installed board |
|---|---|
| immutable Snapshot baseline | live repositories for the installed codename |
| pinned package baseline for build/release audit | normal security/package maintenance |
| exact Snapshot recorded in metadata | `apt upgrade` does not change AtlANTian release identity |
| may wait for release batching when Debian alone changes | never waits for image publication to receive ordinary Debian updates |

`apt update`, `apt upgrade` and `apt install` update the running Debian userspace.
They do not create an AtlANTian release, replace the custom AtlANTian kernel or
change Debian major. AtlANTian kernel/platform changes come through a verified
AtlANTian release; this keeps the board-specific kernel configuration, DT and boot
contract tested as one product rather than allowing a generic Debian kernel to
replace it accidentally.

APT repository indexes are stored in a bounded volatile workspace. Downloaded
`.deb` payloads use normal storage-backed APT staging and are configured not to be
retained after installation, avoiding a large RAM commitment on 512 MiB boards.

## Debian-major transition

A Debian-major transition changes the **first component** of the AtlANTian release
line and is always deliberate. Automation may report Debian `N+1`, but it never
edits `DEBIAN_MAJOR`, `DEBIAN_CODENAME` or starts the transition.

**SD:** once a compatible next-major AtlANTian release exists,
`atlantian-sysupgrade` supports only `N → N+1`, stages resumable state and manages
AtlANTian-owned APT sources.

**NAND:** cross-major rebasing is intentionally unsupported. Boot the next-major
unified SD image, perform a clean NAND installation, then restore only
known-compatible application/user data and reinstall required packages.

See [Upgrading](UPGRADING.md) for operator steps.

## Watcher recovery and release batching

Snapshot lag and partially published Debian metadata are retried without changing
the configured release generation.

After a protected upstream-input commit, there is a narrow failure window before
an eligible `Build & Release` dispatch. On a later no-change watcher run,
AtlANTian compares the Debian Snapshot, Linux pin and U-Boot pin in current
`main` with the latest published AtlANTian tag. An unreleased Linux/U-Boot delta
is immediately release-eligible; a Debian-only delta is dispatched only when the
normal release-input count has reached five. This preserves recovery without
turning routine Debian Snapshot churn into one image release per day.

The watcher currently uses the existing internal `origin=debian-watch` dispatch
identifier understood by `build-release.yml`; despite that compatibility name,
the dispatched transaction may contain Debian, Linux and U-Boot input changes.

GitHub may disable scheduled workflows after prolonged inactivity in a public
repository. If the source tree has had no commit for 45 days, the watcher may
create one empty maintenance heartbeat through the same protected-main path. The
heartbeat changes no release input and does not dispatch `Build & Release`.
