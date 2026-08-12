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

## Volatile APT workspace

Both editions keep disposable APT repository data in `/run/apt`, backed by tmpfs
with a **50% of RAM size limit**. This is a ceiling, not preallocated memory; tmpfs
uses pages on demand and can benefit from zram under pressure.

APT uses:

```text
/run/apt/lists/      repository indexes
/run/apt/archives/   downloaded .deb files
```

These disappear at reboot. Persistent package state remains in `/var/lib/dpkg`
and APT configuration remains under `/etc/apt`.

Consequences:

- run `apt update` again after reboot before repository-backed searches/upgrades;
- repository indexes stay gzip-compressed;
- description translations and Contents indexes are disabled by default;
- persistent APT `pkgcache`/`srcpkgcache` files are not generated.

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

Ordinary `apt` operations modify only the active writable layer.

A same-major NAND platform upgrade creates a fresh target upper and migrates
selected persistent user/admin deltas plus manual package intent rather than
copying the old upper wholesale. This avoids carrying an old dpkg database,
package payloads and whiteouts over a new immutable base.

Exact preserved namespaces, reconciliation and failure behavior are defined in
[Upgrading](UPGRADING.md).
