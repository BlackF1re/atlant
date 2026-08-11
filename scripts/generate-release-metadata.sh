#!/usr/bin/env bash
# Generate machine-readable metadata for the unified SD image and its embedded
# NAND installation payload.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT"

IMAGE=${1:?usage: generate-release-metadata.sh IMAGE [OUTPUT] [NAND_MANIFEST]}
OUTPUT=${2:-$(dirname "$IMAGE")/RELEASE-METADATA.json}
NAND_MANIFEST=${3:-}
[[ -s $IMAGE ]] || { echo "release image is missing: $IMAGE" >&2; exit 2; }
[[ -z $NAND_MANIFEST || -s $NAND_MANIFEST ]] || { echo "NAND manifest is missing: $NAND_MANIFEST" >&2; exit 2; }

# Filesystem occupancy must be measured from the finished image itself. Loop
# setup and read-only mounts require root; direct local invocations are promoted
# in the same way as the rest of the image-assembly path.
if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi
for cmd in losetup mount umount sfdisk python3; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 69; }
done

. config/release.env
. config/debian-snapshot.env
. config/u-boot.env
export DEBIAN_CODENAME DEBIAN_MAJOR DEBIAN_SNAPSHOT_TIMESTAMP
export ATLANTIAN_VERSION ATLANTIAN_DEB_VERSION ATLANTIAN_SOURCE_ID ATLANTIAN_RELEASE_ID
export ATLANTIAN_SOURCE_REVISION ATLANTIAN_KERNEL_VERSION ATLANTIAN_KERNEL_LOCALVERSION
export ATLANTIAN_KERNEL_COMMIT ATLANTIAN_UBOOT_VERSION ATLANTIAN_UBOOT_COMMIT

python3 - "$IMAGE" "$OUTPUT" "$NAND_MANIFEST" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

image, output, nand_manifest = sys.argv[1:4]
mib = 1024 * 1024


def filesystem_stats(path, filesystem, partition_bytes):
    stat = os.statvfs(path)
    block = stat.f_frsize or stat.f_bsize
    total = stat.f_blocks * block
    free = stat.f_bfree * block
    available = stat.f_bavail * block
    used = total - free
    reserved = max(0, free - available)
    return {
        "filesystem": filesystem,
        "partition_bytes": partition_bytes,
        "partition_mib_exact": partition_bytes / mib,
        "total_bytes": total,
        "used_bytes": used,
        "available_bytes": available,
        "reserved_bytes": reserved,
        "used_percent": round((used / total * 100.0) if total else 0.0, 2),
    }


def wait_for_partition(path):
    for _ in range(30):
        if os.path.exists(path):
            return
        time.sleep(0.1)
    raise SystemExit(f"loop partition did not appear: {path}")


def image_layout(path):
    ptable = json.loads(subprocess.check_output(["sfdisk", "--json", path], text=True))["partitiontable"]
    parts = ptable.get("partitions", [])
    if len(parts) != 2:
        raise SystemExit(f"expected exactly two partitions in {path}, found {len(parts)}")
    sector = int(ptable.get("sectorsize", 512))
    boot = int(parts[0]["size"]) * sector
    root = int(parts[1]["size"]) * sector
    image_bytes = os.path.getsize(path)
    partitions = boot + root
    overhead = image_bytes - partitions
    if overhead < 0:
        raise SystemExit(f"partition sizes exceed image size: {path}")
    for label, value in {"BOOT":boot,"ROOT":root,"BOOT+ROOT":partitions,"image":image_bytes,"overhead":overhead}.items():
        if value % mib:
            raise SystemExit(f"{label} size is not exact MiB in {path}: {value}")

    loop = subprocess.check_output(["losetup", "--find", "--show", "--partscan", path], text=True).strip()
    boot_device = loop + "p1"
    root_device = loop + "p2"
    mount_root = tempfile.mkdtemp(prefix="atlantian-release-metadata.")
    boot_mount = os.path.join(mount_root, "boot")
    root_mount = os.path.join(mount_root, "root")
    os.mkdir(boot_mount)
    os.mkdir(root_mount)
    mounted = []
    try:
        wait_for_partition(boot_device)
        wait_for_partition(root_device)
        subprocess.run(["mount", "-o", "ro", boot_device, boot_mount], check=True)
        mounted.append(boot_mount)
        subprocess.run(["mount", "-o", "ro,noload", root_device, root_mount], check=True)
        mounted.append(root_mount)
        filesystems = {
            "boot": filesystem_stats(boot_mount, "vfat", boot),
            "root": filesystem_stats(root_mount, "ext4", root),
        }
    finally:
        for target in reversed(mounted):
            subprocess.run(["umount", target], check=False)
        subprocess.run(["losetup", "-d", loop], check=False)
        shutil.rmtree(mount_root, ignore_errors=True)

    return {
        "boot_bytes": boot, "boot_mib": boot // mib,
        "root_bytes": root, "root_mib": root // mib,
        "boot_plus_root_bytes": partitions, "boot_plus_root_mib": partitions // mib,
        "image_bytes": image_bytes, "image_mib": image_bytes // mib,
        "layout_overhead_bytes": overhead, "layout_overhead_mib": overhead // mib,
        "filesystems": filesystems,
    }


storage = image_layout(image)
package_manifest = os.path.splitext(image)[0] + ".packages.tsv"
if not os.path.isfile(package_manifest):
    raise SystemExit(f"Debian package manifest is missing: {package_manifest}")
with open(package_manifest, encoding="utf-8") as stream:
    package_count = sum(1 for line in stream if line.strip())
if package_count <= 0:
    raise SystemExit("Debian package manifest is empty")

metadata = {
    "schema_version": 1,
    "release": os.environ["ATLANTIAN_VERSION"],
    "package_version": os.environ["ATLANTIAN_DEB_VERSION"],
    "build_id": os.environ["ATLANTIAN_SOURCE_ID"],
    "source_revision": os.environ["ATLANTIAN_SOURCE_REVISION"],
    "release_id": os.environ["ATLANTIAN_RELEASE_ID"],
    "image": os.path.basename(image),
    "storage": storage,
    "platform": {
        "board": "Bitmain Antminer S9",
        "soc": "Xilinx Zynq-7010",
        "supported_ram_mib": [512, 1024],
    },
    "debian": {
        "major": int(os.environ["DEBIAN_MAJOR"]),
        "codename": os.environ["DEBIAN_CODENAME"],
        "snapshot": os.environ["DEBIAN_SNAPSHOT_TIMESTAMP"],
        "package_count": package_count,
    },
    "kernel": {
        "version": os.environ["ATLANTIAN_KERNEL_VERSION"] + os.environ["ATLANTIAN_KERNEL_LOCALVERSION"],
        "commit": os.environ["ATLANTIAN_KERNEL_COMMIT"],
    },
    "u_boot": {"version": os.environ["ATLANTIAN_UBOOT_VERSION"], "commit": os.environ["ATLANTIAN_UBOOT_COMMIT"]},
    "products": {
        "sd": {"image": os.path.basename(image), "storage": storage},
    },
}

if nand_manifest:
    with open(nand_manifest, encoding="utf-8") as f:
        n = json.load(f)
    if n.get("release") != os.environ["ATLANTIAN_VERSION"]:
        raise SystemExit("NAND manifest release identity mismatch")
    root_bytes = int(n["volumes"]["rootfs"]["bytes"])
    boot_bytes = int(n["nand"]["boot_bytes"])
    deployed = boot_bytes + root_bytes
    minimum_overlay_bytes = int(n["volumes"]["overlay"]["minimum_lebs"]) * int(n["nand"]["leb_bytes"])
    n["deployed_base_bytes"] = deployed
    n["deployed_base_mib_exact"] = deployed / mib
    n["rootfs_volume_mib_exact"] = root_bytes / mib
    n["boot_mib"] = boot_bytes // mib
    n["volumes"]["overlay"]["minimum_bytes"] = minimum_overlay_bytes
    n["volumes"]["overlay"]["minimum_mib_exact"] = minimum_overlay_bytes / mib
    n["bundle"] = f"atlantian-nand-{os.environ['ATLANTIAN_VERSION']}.tar.zst"
    metadata["products"]["nand"] = {
        "install_source_image": os.path.basename(image),
        "installed": n,
    }

with open(output, "w", encoding="utf-8") as f:
    json.dump(metadata, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "Created release metadata: $OUTPUT"
