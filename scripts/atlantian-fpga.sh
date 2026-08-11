#!/bin/sh
# Profile-oriented control plane for Zynq FPGA Manager + FPGA Region.
set -eu

# The environment overrides are intentionally undocumented production ABI;
# they make the helper testable against a fake sysfs tree during image CI.
firmware_dir=${ATLANTIAN_FIRMWARE_DIR:-/lib/firmware}
manager=${ATLANTIAN_FPGA_MANAGER:-/sys/class/fpga_manager/fpga0}
overlays=${ATLANTIAN_OVERLAY_ROOT:-/sys/kernel/config/device-tree/overlays}

usage() {
    cat >&2 <<'EOF'
Usage:
  atlantian-fpga status
  atlantian-fpga apply <instance> <dtbo-relative-to-/lib/firmware>
  atlantian-fpga remove <instance>

The DTBO must describe an FPGA Region and carry firmware-name. Applying it
programs the PL first and then creates the matching Linux AXI devices.
EOF
    exit 2
}

require_manager() {
    [ -d "$manager" ] || {
        echo "FPGA Manager fpga0 is not available" >&2
        exit 1
    }
}

status() {
    require_manager
    printf 'manager: %s\n' "$manager"
    printf 'name: '
    cat "$manager/name" 2>/dev/null || printf 'unknown\n'
    printf 'state: '
    cat "$manager/state" 2>/dev/null || printf 'unknown\n'
}

safe_name() {
    case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
}

apply() {
    [ "$#" -eq 2 ] || usage
    require_manager
    instance=$1
    image=$2
    safe_name "$instance" || { echo "unsafe overlay instance name" >&2; exit 2; }

    # The firmware loader accepts a name relative to /lib/firmware.  Reject
    # absolute paths and traversal so the helper cannot be used as a generic
    # privileged file reader/writer.
    case "$image" in
        ''|/*|*'..'*|*'//'*)
            echo "firmware name must be a safe relative path" >&2
            exit 2
            ;;
    esac
    [ -f "$firmware_dir/$image" ] || {
        echo "DTBO not found: $firmware_dir/$image" >&2
        exit 1
    }
    [ -d "$overlays" ] || {
        mountpoint -q /sys/kernel/config 2>/dev/null || mount -t configfs none /sys/kernel/config
    }
    [ -d "$overlays" ] || { echo "OF configfs overlay API is unavailable" >&2; exit 1; }
    [ ! -e "$overlays/$instance" ] || { echo "profile instance already exists" >&2; exit 1; }
    mkdir "$overlays/$instance"
    if ! printf '%s\n' "$image" > "$overlays/$instance/path"; then
        rmdir "$overlays/$instance" 2>/dev/null || true
        exit 1
    fi
    cat "$overlays/$instance/status"
    status
}

remove() {
    [ "$#" -eq 1 ] || usage
    safe_name "$1" || { echo "unsafe overlay instance name" >&2; exit 2; }
    [ -d "$overlays/$1" ] || { echo "profile instance is not active" >&2; exit 1; }
    rmdir "$overlays/$1"
}

case "${1-}" in
    status) [ "$#" -eq 1 ] || usage; status ;;
    apply) shift; apply "$@" ;;
    remove) shift; remove "$@" ;;
    *) usage ;;
esac
