# Persistence

This document owns writable-state behavior. NAND geometry/ECC is documented in
[NAND](NAND.md); release-to-release migration is documented in
[Upgrading](UPGRADING.md).

## SD boot

```text
p1 FAT   /boot
p2 ext4  /
```

ROOT expands across the card on first boot. Debian package state, `/etc`, `/root`,
`/home`, machine identity and SSH keys persist normally.

The FAT BOOT partition also carries two complete kernel+DT FIT slots. They are
boot payload redundancy, not a second writable root filesystem. The active-slot
marker is intentionally tiny so an SD platform update can commit after the
inactive FIT has already been fully written, verified and synced.

## NAND boot

```text
static UBI -> SquashFS/Zstd, ro        immutable lower
dynamic UBI -> UBIFS/LZO, rw,noatime   internal/default upper
recovery SD ext4 directory             optional external upper
```

Early initramfs assembles OverlayFS before systemd. `/tmp` and persistent journal
storage are avoided on NAND; zram replaces persistent swap.

The internal `overlay` UBI volume is created with `ubimkvol -m`, so its actual
size depends on the compressed base, UBI reserves and real bad blocks.

## Volatile APT index workspace

Both editions keep disposable **repository indexes** in `/run/apt`, backed by a
tmpfs with a fixed **96 MiB ceiling**. This is a maximum, not preallocated memory;
tmpfs consumes pages only for data actually stored.

APT uses:

```text
/run/apt/lists/             repository indexes (volatile)
/var/cache/apt/archives/    downloaded .deb transaction staging (storage-backed)
```

Downloaded package archives are configured not to be retained after installation.
This split is deliberate: repository indexes remain disposable, while a large
`apt upgrade` is not forced to fit inside RAM. The previous design that put both
indexes and `.deb` payloads in a tmpfs sized to 50% of RAM is no longer used.

Persistent package state remains in `/var/lib/dpkg` and APT configuration remains
under `/etc/apt`.

Consequences:

- run `apt update` again after reboot before repository-backed searches/upgrades;
- repository indexes stay gzip-compressed;
- description translations and Contents indexes are disabled by default;
- persistent APT `pkgcache`/`srcpkgcache` files are not generated;
- large package downloads consume normal writable storage during the transaction,
  not a large fraction of system RAM;
- APT is asked not to keep successfully downloaded packages after installation.

Package-specific APT configuration may still re-enable an index target when a
tool explicitly requires it.

## External NAND upper

After NAND boot, the paired recovery SD can be adopted:

```sh
atlantian-storage adopt
```

The command does **not** repartition or erase the card. It creates:

```text
/.atlantian-extroot/
├─ token
├─ upper/
└─ work/
```

on the card's existing ext4 ROOT partition, copies the current internal writable
state and records a matching token internally.

At boot:

```text
matching adopted card present -> SquashFS lower + SD upper
card absent / token mismatch   -> SquashFS lower + internal UBIFS upper
```

The internal and external uppers are independent after adoption; there is no
pooling or automatic two-way synchronization.

## What upgrades preserve

Ordinary `apt` operations modify only the active writable layer and use live
repositories for the installed Debian codename.

On SD, an AtlANTian platform update changes package state in the ext4 root and
commits the custom kernel+DT through the inactive FAT FIT slot; the previous FIT
remains the boot fallback. This does not create a separate persistence layer.

A same-major NAND platform upgrade creates a fresh target upper and migrates
selected persistent user/admin deltas plus manual package intent rather than
copying the old upper wholesale. This avoids carrying an old dpkg database,
package payloads and whiteouts over a new immutable base.

Exact preserved namespaces, reconciliation and failure behavior are defined in
[Upgrading](UPGRADING.md).
