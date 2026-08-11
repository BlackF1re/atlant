# Upgrading AtlANTian

SD is a normal writable filesystem. NAND uses an immutable boot/base plus one
active writable OverlayFS upper.

| Goal | SD boot | NAND boot |
|---|---|---|
| Debian packages | normal APT | normal APT into active upper |
| Install package | `apt install <package>` | same |
| AtlANTian base/kernel/boot | `atlantian-sysupgrade` | `atlantian-sysupgrade` stages the target NAND bundle on the paired recovery SD, then maintenance continues from SD |
| Next Debian major | explicit AtlANTian release-line transition | clean NAND reinstall |

Runtime APT follows the installed Debian codename, not moving `stable`.

## Release semantics

AtlANTian releases use:

```text
<Debian major>.<AtlANTian minor>.<AtlANTian patch>[-prerelease]
```

Examples: `13.1.0-alpha.1`, `13.1.0-beta.1`, `13.1.0-rc.1`, `13.1.0`,
`13.1.1`, `13.2.0`. The source revision and Debian Snapshot timestamp are
separate metadata.

A daily Debian Snapshot refresh does **not** create a new AtlANTian semantic
release. It only refreshes the reproducible factory input and triggers a
validation-only build. A public AtlANTian release requires an explicit version
change and explicit publication.

Stable installations do not automatically opt into GitHub prereleases. An
installation already on an alpha/beta/rc line may receive newer prereleases on
that line until stable is reached.

## SD updates

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

The updater verifies version-matched AtlANTian packages, updates platform/kernel
metadata and refreshes FAT boot assets. Human-facing release versions use normal
SemVer-style prerelease syntax; `.deb` packages use Debian-native ordering, e.g.
`13.1.0-alpha.1` → `13.1.0~alpha.1-1`.

Debian-major SD transitions are limited to `N → N+1` and use resumable state.
Automation may report a new Debian major, but never initiates that transition or
changes the release line by itself.

## NAND package maintenance

No special command is needed:

```sh
apt update
apt upgrade
apt install <package>
```

Writes land in the active internal UBIFS upper or adopted recovery-SD upper. The
SquashFS lower and raw boot region are unchanged.

## Same-major NAND base update

Insert the **paired recovery SD** while booted from NAND and run:

```sh
atlantian-sysupgrade --check
atlantian-sysupgrade --notes
atlantian-sysupgrade
```

The NAND edition of `atlantian-sysupgrade`:

1. finds the newest compatible same-major release;
2. requires the paired install/recovery card;
3. downloads the matching `atlantian-nand-<release>.tar.zst` to that card;
4. verifies the public SHA-256 and the bundle's internal checksums/release ID;
5. records the prepared target on the recovery SD;
6. asks for the physical **NAND → SD** jumper change;
7. reboots into the recovery card.

At the next root login from SD, AtlANTian detects the prepared target and starts:

```sh
atlantian-nand-upgrade
```

The verified target NAND bundle is staged on the recovery card's ext4 ROOT
filesystem, so no separate target SD image is required.

### Rebase policy

Before destructive writes, the SD-side updater verifies the current/target
release, geometry, bundle checksums and all adopted writable layers.

For each writable upper it captures persistent user/admin deltas from:

```text
/etc        /root       /home       /usr/local
/opt        /srv        /var/local  /var/lib
/var/spool  /var/www
```

APT/dpkg/systemd/ucf/initramfs package-management state is excluded from copied
`/var/lib` data. Package payload namespaces such as `/usr`, `/bin` and `/lib` are
not copied from the writable upper.

Separately, AtlANTian records manually added packages and package holds.

### Transaction

After literal `UPGRADE`:

1. SD U-Boot programs and twice read-back-verifies the target raw boot payload;
2. SD Linux validates the rebase snapshots before formatting UBI;
3. it writes/verifies the target static SquashFS rootfs;
4. it creates a maximum-size UBIFS overlay and fresh `upper/work`;
5. persistent deltas are replayed against the target lower;
6. an adopted external upper, when present, is recreated and rebased separately;
7. after **SD → NAND** handoff, first boot reconciles package holds/manual package
   intent and runs `dpkg --audit`.

A complete writable upper, its dpkg database and package whiteouts are never
copied wholesale onto the target base.

If package reconciliation cannot finish, its marker remains and systemd retries
on a later boot; the immutable target base remains intact.

### External upper requirement

If NAND records an adopted recovery-SD token, that exact card must be present for
a full base update. AtlANTian refuses to replace the lower beneath an unavailable
external upper. Normal NAND operation without the card still uses the independent
internal upper.

## Debian-major transition

A Debian-major transition changes the first component of the AtlANTian release
line and is always explicit.

**SD:** a published next-major AtlANTian release may perform only `N → N+1` through
the staged/resumable updater.

**NAND:** state is not rebased automatically across Debian majors. For `N → N+1`:

1. back up required application/user data;
2. boot the next-major unified image from SD;
3. run a clean `atlantian-nand-install`;
4. transfer only known-compatible state and reinstall required packages.

## Recovery

For SD, use normal Debian tools plus `atlantian-sysupgrade --check`.

For NAND boot/base problems, select physical SD boot and use the paired AtlANTian
recovery card. Do not write raw `/dev/mtd*` with generic `dd`.

Storage internals: [NAND](NAND.md). Persistent state: [Persistence](PERSISTENCE.md).
Build/update gates: [Pipeline](PIPELINE.md).
