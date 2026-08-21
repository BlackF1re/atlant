# Upgrading AtlANTian

This document owns user-facing update behavior. Release publication mechanics and
upstream-input tracking are in [Pipeline](PIPELINE.md); Debian
Snapshot/major-generation policy is in [Debian lifecycle](DEBIAN-LIFECYCLE.md).

| Goal | SD boot | NAND boot |
|---|---|---|
| Debian packages | normal live APT | normal live APT into active upper |
| Install package | `apt install <package>` | same |
| AtlANTian platform/kernel | `atlantian-sysupgrade`; kernel+DTB use transactional A/B FIT slots | stage verified target on paired recovery SD, then continue from SD |
| Early U-Boot | retained during online update; newer bootloader arrives with a freshly flashed image | release-matched raw boot is updated through recovery-SD maintenance |
| Next Debian major | staged explicit `N → N+1` transition | clean NAND reinstall |

Runtime APT follows the installed Debian codename, never moving `stable` and never
waiting for a new AtlANTian image release to receive ordinary Debian updates.

## Release selection

Check a running system with:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
```

The updater selects complete published releases from the repository recorded in
the installation. Same-major candidates are preferred before the immediate next
Debian major.

Stable installations do not opt into prereleases. An installation already on an
alpha/beta/rc line may receive newer prereleases until the stable release is
reached.

The daily upstream watcher may update the factory Debian Snapshot, Linux LTS
patchlevel and stable U-Boot input in one protected transaction. Debian-only
factory changes may wait for release batching; this has no effect on normal live
APT maintenance. A kernel/U-Boot input change makes the combined factory
transaction release-eligible immediately so userspace and board boot inputs are
not published as separate artificial releases.

### Release version vs Debian package version

AtlANTian release identity and Debian package identity are related but use
different strings. For a prerelease:

```text
AtlANTian release:       X.Y.Z-alpha.N
Debian package Version:  X.Y.Z~alpha.N-1
public .deb filename:    atlantian-kernel_X.Y.Z.alpha.N-1_armhf.deb
```

The `~` stays inside Debian package metadata because Debian sorts it before the
corresponding stable version. Public GitHub filenames replace that `~` with `.`.
`atlantian-sysupgrade` verifies Package, Version, Architecture and published
SHA-256 rather than trusting the filename. Legacy prerelease naming used by older
AtlANTian releases remains accepted for compatibility.

## Ordinary Debian package maintenance

On either storage edition:

```sh
apt update
apt upgrade
apt install <package>
```

On SD, writes go directly to ext4 ROOT. On NAND, writes go to the active OverlayFS
upper: internal UBIFS or adopted recovery-SD upper. Ordinary APT does not replace
the custom AtlANTian kernel, SD boot firmware, immutable NAND base or raw NAND
boot region.

Factory builds use an immutable Debian Snapshot for reproducibility; installed
systems use the live repositories for their fixed codename. These are deliberately
separate policies.

APT repository indexes live in `/run/apt/lists` on a **bounded 96 MiB tmpfs**.
Downloaded `.deb` files use APT's normal storage-backed archive staging and are
configured not to be retained after installation. This avoids the previous risk
where a large transaction could use a tmpfs sized to half of installed RAM,
particularly on a 512 MiB board.

## SD platform update

Run:

```sh
atlantian-sysupgrade
```

For a same-major release, the updater:

1. discovers a complete compatible Release;
2. after confirmation, records the best-effort update marker and downloads the
   exact three advertised AtlANTian `.deb` assets plus `SHA256SUMS`;
3. verifies package identity and checksum independently of the filename;
4. installs the version-locked platform/kernel/release package set;
5. refreshes Debian packages from the installed release's managed repositories;
6. reboots.

The kernel/platform/release package set is not intentionally mixed across
AtlANTian releases.

### Transactional SD kernel/DT update

Current factory images use the existing 48 MiB FAT BOOT partition with two FIT
slots:

```text
atlantian-A.itb
atlantian-B.itb
atlantian-slot-B   # present only when B is active
```

Each `.itb` contains the matching Linux kernel and device tree in one FIT object
with SHA-256 hashes. No second rootfs, extra partition or permanent update reserve
is created.

During a normal platform update the kernel package:

1. chooses the **inactive** FIT slot;
2. writes the complete new FIT to a hidden temporary name;
3. byte-compares the staged file with the package payload;
4. `sync`s it before exposing the slot;
5. renames it to the inactive A/B slot and syncs again;
6. commits the transaction by changing only the tiny active-slot marker;
7. leaves the previous active FIT untouched as rollback.

At boot, `boot.scr` tries the selected FIT first and the other FIT second. A power
loss before the marker commit leaves the previous slot selected. A power loss
after the commit still leaves the previous complete slot available as fallback.
Kernel and DTB are never updated as independent boot files, so the normal update
cannot create a mixed kernel/device-tree generation.

The active-A representation is the **absence** of `atlantian-slot-B`; switching
back to A therefore removes that marker only after A is fully staged. The FAT
filesystem is not treated as a general multi-file transaction—the design reduces
the commit point to one tiny directory-entry change after all large writes are
complete.

### Migration from historical SD layout

Older AtlANTian releases booted separate `uImage` and `devicetree.dtb` files.
Their first update to the transactional layout is ordered as follows:

1. write and verify both FIT A and FIT B;
2. only after both exist, atomically replace `boot.scr` with the FIT-aware loader;
3. begin with slot A active;
4. retain the old `uImage`/DTB as an additional migration fallback;
5. remove those legacy payloads after a later normal A/B transaction succeeds.

The FIT-aware boot script also contains a legacy fallback path specifically for
this migration window.

### Why online updates do not rewrite `BOOT.bin`/`u-boot.img`

The BootROM/SPL/U-Boot chain is earlier than the A/B FIT commit point. Rewriting
those files in-place on the same FAT partition would reintroduce a power-loss
window before the transactional kernel loader exists. AtlANTian therefore keeps
the installed SD `BOOT.bin`, `u-boot.img` and compatible `boot.scr` during normal
A/B platform updates.

Freshly flashed images contain the current validated stable U-Boot. If a future
change requires a different online boot ABI/loader, the kernel package fails
closed and requests a reflash rather than silently weakening the transaction
model. This costs no extra rootfs and avoids pretending that early boot firmware
has redundancy it does not have.

## Same-major NAND platform update

While booted from NAND, insert the **paired recovery SD** and run:

```sh
atlantian-sysupgrade
```

The NAND updater:

1. selects the newest compatible same-major release;
2. requires the paired install/recovery card;
3. after confirmation, records the best-effort update marker and downloads the
   matching `atlantian-nand-<release>.tar.zst` to that card;
4. verifies public `SHA256SUMS`, bundle checksums and release identity;
5. records the prepared target on the recovery SD;
6. asks for physical **NAND → SD** handoff;
7. reboots into the recovery card.

At the next root login from SD, the prepared maintenance transaction starts
`atlantian-nand-upgrade`. A separately flashed target SD image is not required.
The release-matched NAND raw boot region—including the target NAND U-Boot—is
updated through this recovery transaction, not through live writes from the NAND
root filesystem.

### Rebase policy

Before destructive writes the SD-side updater validates current/target release,
NAND geometry, target bundle and writable-layer state.

Persistent user/admin deltas are captured from:

```text
/etc        /root       /home       /usr/local
/opt        /srv        /var/local  /var/lib
/var/spool  /var/www
```

Package-management state under `/var/lib` is excluded where copying it would bind
the new base to old dpkg/APT/systemd/ucf/initramfs state. Package payload
namespaces such as `/usr`, `/bin` and `/lib` are not copied from the old upper.
Manual package intent and package holds are recorded separately.

After literal `UPGRADE`:

1. SD U-Boot programs and twice read-back-verifies the target raw boot payload;
2. SD Linux validates saved deltas before formatting UBI;
3. the target SquashFS base is written and verified;
4. fresh writable upper/work state is created;
5. persistent deltas are replayed against the target lower;
6. an adopted external upper, when present, is recreated/rebased separately;
7. after **SD → NAND** handoff, first boot reconciles package holds/manual package
   intent and runs `dpkg --audit`.

A complete old upper, old dpkg database and old package whiteouts are never copied
wholesale onto the new base.

If package reconciliation cannot finish, its marker remains and systemd retries on
a later boot; the immutable target base remains intact.

### Adopted external-upper requirement

If NAND records an adopted recovery-SD token, that exact card must be present for
a platform rebase. AtlANTian refuses to replace the lower beneath an unavailable
external upper. Normal NAND boot without the card may still use the independent
internal upper.

## Download metrics

Current releases publish the versioned image:

```text
atlantian-<release>.img.xz
```

**Image Downloads** is the cumulative GitHub `download_count` for all published
AtlANTian SD image asset naming generations: current versioned `.img.xz`,
historical versioned `.img`, and the one legacy unversioned `atlantian.img`.
Package, checksum and metadata downloads are excluded from this aggregate.

Every release also publishes the tiny stable `atlantian-update.json` marker.
`atlantian-sysupgrade --check` and `--notes` do **not** download it. After the user
confirms an update, or uses `--yes`, the SD/NAND updater attempts to fetch it once
and caches a valid marker for that target release. Failure to fetch or validate the
marker never blocks the update.

**System Updates** sums `download_count` only for those update-marker assets. It is
therefore an approximate count of update transactions that reached this stage,
not a count of unique boards and not proof that every update completed. Deleting
the staging cache and starting the same target again can add another download.

AtlANTian adds no installation ID, serial number or device token to the marker
request. The public badges consume only GitHub's aggregate Release-asset
`download_count`; they make no claim about what network/service logs GitHub itself
may retain.

The Pages-backed totals and per-file Release counters refresh after publication
and hourly. A completed `Build & Release` triggers the refresh only when a Release
exists for that exact source SHA, so plan-only runs do not perform a Pages deploy.
GitHub and Shields caching can delay the displayed value.

CI release-upgrade validation uses retained, SHA-sealed Actions artifacts rather
than public Release assets, so production validation does not increase the image
or update-marker counters.

## Debian-major transition

A Debian-major transition changes the first component of the AtlANTian version and
is always explicit.

### SD: `N → N+1`

A published next-major AtlANTian release may be installed only one Debian major at
a time. `atlantian-sysupgrade` manages the staged/resumable transition and managed
APT-source changes.

### NAND: clean reinstall

Cross-major NAND rebase is intentionally unsupported:

1. back up required application/user data;
2. boot the next-major unified AtlANTian image from SD;
3. run a clean `atlantian-nand-install`;
4. restore only known-compatible data and reinstall required packages.

## Recovery

For an SD system, use normal Debian recovery tools plus
`atlantian-sysupgrade --check`. If the selected FIT cannot boot, the boot script
tries the other complete slot automatically. A deliberately selected previous
slot can also be restored from U-Boot/FAT if manual recovery is needed.

For NAND boot/base trouble, select physical SD boot and use the paired AtlANTian
recovery card. Never write raw `/dev/mtd*` with generic `dd`.

Storage internals: [NAND](NAND.md). Writable-state model:
[Persistence](PERSISTENCE.md).
