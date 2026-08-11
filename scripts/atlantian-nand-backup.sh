#!/bin/sh
# Create read-only recovery dumps of the Antminer S9 raw NAND.
# This tool never erases or writes the MTD device.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 77; }
for cmd in nanddump sha256sum awk sed date; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 69; }
done
[ -r /proc/mtd ] || { echo '/proc/mtd is unavailable' >&2; exit 69; }

# Preserve the caller-supplied output directory before parsing /proc/mtd with
# positional parameters below. `set -- $line` is intentionally local parsing,
# not a replacement for the script's original $1 argument.
requested_out=${1:-}

line=$(awk -F: '$2 ~ /"pl35x-nand-controller"/ {print; n++} END {if (n != 1) exit 1}' /proc/mtd) || {
  echo 'expected exactly one MTD device named pl35x-nand-controller' >&2
  cat /proc/mtd >&2
  exit 65
}
name=${line%%:*}
set -- $line
size_hex=$2
erase_hex=$3
case "$name" in mtd[0-9]*) ;; *) echo "unexpected MTD name: $name" >&2; exit 65 ;; esac

# Supported production boards use a 256 MiB SLC device. Refuse to dump an
# unexpected geometry under this board-specific command name.
[ "$size_hex" = 10000000 ] || {
  echo "unexpected NAND size 0x$size_hex; expected 0x10000000 (256 MiB)" >&2
  exit 65
}
[ "$erase_hex" = 00020000 ] || {
  echo "unexpected erase size 0x$erase_hex; expected 0x00020000 (128 KiB)" >&2
  exit 65
}

dev=/dev/$name
[ -c "$dev" ] || { echo "missing character MTD device: $dev" >&2; exit 69; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=${requested_out:-"$PWD/atlantian-nand-backup-$stamp"}
umask 077
mkdir -p "$out"

{
  echo 'AtlANTian Antminer S9 NAND backup'
  echo "created_utc=$stamp"
  echo "device=$dev"
  echo "mtd_name=pl35x-nand-controller"
  echo "size_hex=$size_hex"
  echo "erase_hex=$erase_hex"
  echo
  cat /proc/mtd
  echo
  for attr in name size erasesize writesize oobsize ecc_strength ecc_step_size; do
    path="/sys/class/mtd/$name/$attr"
    [ -r "$path" ] && printf '%s=%s\n' "$attr" "$(cat "$path")"
  done
} >"$out/NAND-INFO.txt"

# The forensic image is the primary recovery artifact: ECC is bypassed and OOB
# is retained, including factory bad-block markers and the original ECC bytes.
# dumpbad preserves physical page order instead of silently skipping bad blocks.
echo "Creating raw+OOB forensic dump from $dev ..."
nanddump --quiet --noecc --oob --bb=dumpbad --file="$out/nand-raw-oob.bin" "$dev"

# Also create an address-stable raw main-area image useful for inspection. ECC
# must stay bypassed here as well: a factory image may use a different ECC/OOB
# layout from the currently running kernel. Bad eraseblocks are padded with 0xff
# so logical byte offsets remain aligned to the 256 MiB device.
echo 'Creating padded raw main-area dump ...'
if nanddump --quiet --noecc --omitoob --bb=padbad --file="$out/nand-main-padded.bin" "$dev"; then
  main_status=complete
else
  main_status=failed
  rm -f "$out/nand-main-padded.bin"
  echo 'warning: padded raw main-area dump failed; raw+OOB backup is still retained' >&2
fi
printf 'main_dump=%s\n' "$main_status" >>"$out/NAND-INFO.txt"

(
  cd "$out"
  if [ "$main_status" = complete ]; then
    sha256sum NAND-INFO.txt nand-raw-oob.bin nand-main-padded.bin
  else
    sha256sum NAND-INFO.txt nand-raw-oob.bin
  fi
) >"$out/SHA256SUMS"

# Verify every file we just checksummed before reporting success.
(cd "$out" && sha256sum -c SHA256SUMS)

echo
echo "NAND backup completed: $out"
echo 'Keep NAND-INFO.txt, nand-raw-oob.bin and SHA256SUMS together.'
echo 'Do not use dd to restore a raw NAND device.'
