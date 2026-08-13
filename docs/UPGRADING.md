# Upgrading AtlANTian

This document owns user-facing update behavior. Release publication mechanics are
in [Pipeline](PIPELINE.md); Debian Snapshot discovery/major availability is in
[Debian lifecycle](DEBIAN-LIFECYCLE.md).

| Goal | SD boot | NAND boot |
|---|---|---|
| Debian packages | normal APT | normal APT into active upper |
| Install package | `apt install <package>` | same |
| AtlANTian base/kernel/boot | `atlantian-sysupgrade` | stage verified target on paired recovery SD, then continue from SD |
| Next Debian major | staged explicit `N → N+1` transition | clean NAND reinstall |

Runtime APT follows the installed Debian codename, never moving `stable`.

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

Automatic CI publication and Debian Snapshot refreshes may therefore make a new
AtlANTian version available without any manual version edit in the source tree.

### Release version vs Debian package version

AtlANTian release identity and Debian package identity are related but not the
same string. For a prerelease such as:

```text
AtlANTian release:       13.1.0-alpha.8
Debian package Version:  13.1.0~alpha.8-1
public .deb filename:    atlantian-kernel_13.1.0.alpha.8-1_armhf.deb
```

The `~` remains inside the package metadata because Debian uses it to sort a
prerelease before the corresponding stable version. Public GitHub asset names use
`.` in that filename position. `atlantian-release-check` understands both the
public GitHub form and a canonical `~` filename used by mirrors; `atlantian-sysupgrade`
verifies the actual Package, Version and Architecture fields inside every
`.deb`, plus its published SHA-256, before installation.

For historical prereleases where GitHub normalized a `~` filename after upload
but `SHA256SUMS` still contained the canonical Debian basename, the updater also
accepts that checksum alias for the same internally verified package. New
releases publish checksums using the exact public filenames.

## Ordinary Debian package maintenance

On either storage edition:

```sh
apt update
apt upgrade
apt install <package>
```

On SD, writes go directly to ext4 ROOT. On NAND, writes go to the active OverlayFS
upper (internal UBIFS or adopted recovery-SD upper). This does not replace the
immutable NAND base or raw boot region.

## SD platform update

Run:

```sh
atlantian-sysupgrade
```

For a same-major release, the updater:

1. discovers a complete compatible Release;
2. downloads the exact three advertised AtlANTian `.deb` assets and public
   `SHA256SUMS`;
3. verifies package identity and checksum independently of the filename;
4. installs the version-locked platform/kernel/release package set;
5. refreshes Debian packages from the installed release's managed repositories;
6. reboots.

The kernel/platform/release package set is not intentionally mixed across
AtlANTian releases.

The package post-install scripts update FAT boot files using per-file
write-then-rename replacement. Each file replacement is atomic, but the complete
multi-file boot set is **not one filesystem transaction**. Do not cut power during
a platform update; recovery remains the SD image/reflash path if an interruption
leaves mixed boot assets.

## Same-major NAND platform update

While booted from NAND, insert the **paired recovery SD** and run:

```sh
atlantian-sysupgrade
```

The NAND updater:

1. selects the newest compatible same-major release;
2. requires the paired install/recovery card;
3. downloads the matching `atlantian-nand-<release>.tar.zst` to that card;
4. verifies public `SHA256SUMS`, bundle checksums and release identity;
5. records the prepared target on the recovery SD;
6. asks for physical **NAND → SD** handoff;
7. reboots into the recovery card.

At the next root login from SD, the prepared maintenance transaction starts
`atlantian-nand-upgrade`. A separately flashed target SD image is not required.

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
the new base to the old dpkg/APT/systemd/ucf/initramfs state. Package payload
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

Every release publishes a versioned user image:

```text
atlantian-<release>.img.xz
```

The **Image Downloads** badge sums GitHub's `download_count` only for assets
matching that pattern across all releases. It refreshes after release publication
and hourly, so a new image begins at zero without discarding downloads of earlier
versioned images. Packages, checksums and metadata are excluded.

Every release also publishes the tiny stable `atlantian-update.json` marker.
`atlantian-sysupgrade --check` and `--notes` do **not** download it. After the user
confirms an update (or uses `--yes`), the SD/NAND updater attempts to fetch it once
and caches the valid marker for that target release. Failure to fetch or validate
the marker never blocks the update.

The **System Updates** badge uses the same GitHub Pages refresh as Image Downloads:
it sums `download_count` only for `atlantian-update.json` assets across all
releases, after publication and hourly. It excludes packages, images, checksums and
metadata.

No installation ID, serial number, IP-derived token or other device identifier is
sent by AtlANTian. GitHub only records its normal Release-asset download count.
Consequently **System Updates is not a unique-device counter** and does not prove
that every started update completed successfully. Clearing the staging cache and
retrying can also add another download.

GitHub and Shields may cache a displayed count briefly, so a badge is not a
real-time transaction meter. CI release-upgrade validation uses retained,
SHA-sealed GitHub Actions artifacts rather than public Release assets, so
production validation does not increase either user-facing counter.

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
`atlantian-sysupgrade --check`.

For NAND boot/base trouble, select physical SD boot and use the paired AtlANTian
recovery card. Never write raw `/dev/mtd*` with generic `dd`.

Storage internals: [NAND](NAND.md). Writable-state model:
[Persistence](PERSISTENCE.md).
