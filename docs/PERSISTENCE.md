# Persistence

AtlANTian has one public image and two runtime storage models.

## SD boot

```text
p1 FAT   /boot
p2 ext4  /
```

ROOT expands across the card on first boot. Debian package state, `/etc`, `/root`,
`/home`, machine identity and SSH keys persist normally.

## NAND boot

```text
static UBI -> SquashFS/Zstd, ro       immutable lower
dynamic UBI -> UBIFS/LZO, rw,noatime internal/default upper
recovery SD ext4 directory            optional external upper
```

Early initramfs assembles OverlayFS before systemd. `/tmp` and journal storage are
volatile on NAND; zram replaces persistent swap.

The internal `overlay` UBI volume is created with `ubimkvol -m`, so it receives
all UBI space left after the static root volume and UBI reserves. Its actual size
therefore depends on the compressed base and real bad blocks.

## Volatile APT workspace

Both SD and NAND editions keep APT's disposable repository state out of persistent
storage. A dedicated `/run/apt` tmpfs is mounted at boot and is capped at 50% of
physical RAM; tmpfs allocates pages on demand, so this is a limit rather than a
reservation. Its pages remain swappable and can therefore benefit from AtlANTian's
zram under memory pressure.

APT uses:

```text
/run/apt/lists/      repository indexes
/run/apt/archives/   downloaded .deb files
```

Both disappear at reboot. `/var/lib/dpkg`, installed package payloads and APT
configuration remain persistent. Consequently, after a reboot `apt update` is
required before repository-backed searches, upgrades or installation of packages
that are not already known locally.

Repository indexes are kept gzip-compressed, description translations and Contents
indexes are disabled by default, and APT's persistent `pkgcache`/`srcpkgcache`
files are not generated. Later package-specific APT configuration can still
re-enable an index target when a tool explicitly needs it.

## External upper

After booting NAND, the paired recovery SD can be adopted with:

```sh
atlantian-storage adopt
```

The card is **not repartitioned or erased**. AtlANTian creates
`/.atlantian-extroot/{token,upper,work}` on its existing ext4 ROOT partition,
copies the current internal writable state and stores a matching token internally.

At boot:

```text
matching adopted card present -> SquashFS lower + SD upper
card absent / token mismatch   -> SquashFS lower + internal UBIFS upper
```

The two uppers are independent after adoption. There is no pooling or automatic
two-way synchronization.

## Full base upgrades

Ordinary Debian package updates modify only the active upper.

For a same-major AtlANTian NAND base/kernel/raw-boot update, run from NAND with the
paired recovery SD inserted:

```sh
atlantian-sysupgrade
```

The target bundle is downloaded and verified onto the recovery SD. After the
physical **NAND → SD** handoff and reboot, the prepared maintenance transaction
starts from SD and performs `atlantian-nand-upgrade`.

The updater captures selected persistent user/application deltas plus manual
package intent, writes the target immutable base, creates fresh upper/work
directories and replays the deltas. Package databases and package payload files
come from the target base/current repositories rather than from a complete upper
copy.

Each rebased upper has its own one-shot package-reconciliation marker. A Debian-
major NAND transition uses a clean install.

Exact update policy: [Upgrading](UPGRADING.md). NAND layout/ECC: [NAND](NAND.md).
