# Debian lifecycle

This document owns AtlANTian's Debian-generation and Debian Snapshot policy.
User-facing upgrades are documented in [Upgrading](UPGRADING.md); GitHub CI,
protected-main merge mechanics and release publication are documented in
[Pipeline](PIPELINE.md).

## Policy

| Rule | Behavior |
|---|---|
| Architecture | configured Debian generation must still publish `armhf` |
| Factory input | exact Debian Snapshot metadata is frozen |
| Runtime repositories | installed codename is fixed; moving `stable` is never used |
| Routine Debian change | refresh the frozen Snapshot, validate it, then publish a new AtlANTian release through the normal release gates |
| New Debian major | report availability only; transition remains explicit |
| Failure | keep the last verified Snapshot and configured generation |

A Snapshot refresh changes the reproducible factory package baseline, so a
successful refresh produces the next AtlANTian release in the current release
line. The Snapshot timestamp is recorded separately from the semantic version.

## Daily watcher

`Debian Base Watch` runs daily at **06:17 Asia/Tomsk**. It also runs when its own
protected-maintenance plumbing changes so that those changes are exercised
immediately.

The watcher:

1. reads the configured Debian major/codename and verifies `armhf` availability
   in Debian main, updates and security;
2. compares live Debian Release metadata with the frozen checksums;
3. if Debian changed, waits until Debian Snapshot contains those exact metadata
   bytes, then freezes the new Snapshot timestamp/checksums;
4. validates the new frozen inputs and merges them through the repository's
   protected `main` path;
5. explicitly dispatches `Build & Release` for the resulting protected `main`
   revision;
6. publishes the next AtlANTian release only after the full build/verification
   gates pass;
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
| reproducible package set | normal security/package maintenance |
| exact Snapshot recorded in metadata | `apt upgrade` does not change AtlANTian release identity |

`apt update` and `apt upgrade` update the running Debian userspace. They do not
create an AtlANTian release or change Debian major.

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

## Watcher recovery

Snapshot lag and partially published Debian metadata are retried without changing
the configured release generation.

There is one recoverable failure window after a Snapshot change has reached
`main` but before its `Build & Release` dispatch succeeds. On a no-change watcher
run, AtlANTian compares the four frozen Snapshot input files in current `main`
with the latest published AtlANTian tag. If they differ, the committed Snapshot
has not yet been represented by a published factory baseline, so the watcher
re-dispatches `Build & Release` with `origin=debian-watch`. Once a release contains
those exact Snapshot files, the recovery path becomes a no-op.

GitHub may disable scheduled workflows after prolonged inactivity in a public
repository. If the source tree has had no commit for 45 days, the watcher may
create one empty maintenance heartbeat through the same protected-main path. The
heartbeat changes no release input and does not dispatch `Build & Release`.
