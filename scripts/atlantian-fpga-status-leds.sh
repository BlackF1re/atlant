#!/bin/sh
# Load the optional, board-specific PL status LED profile.
# Failure is deliberately non-fatal: a different full PL design must never
# prevent Linux from booting or being administered over SSH.
set -u

manager=/sys/class/fpga_manager/fpga0
overlay_root=/sys/kernel/config/device-tree/overlays
firmware=/lib/firmware/atlantian/status-leds/atlantian-status-leds.dtbo
instance=status-leds

log() { logger -t atlantian-fpga-status-leds -- "$*" 2>/dev/null || printf '%s\n' "$*" >&2; }

if [ ! -d "$manager" ]; then
    log "FPGA Manager is unavailable; leaving PL unchanged"
    exit 0
fi
if [ ! -f "$firmware" ] || [ ! -f "${firmware%.dtbo}.bin" ]; then
    log "status LED firmware is not installed; leaving PL unchanged"
    exit 0
fi

# Configfs may be mounted by the kernel but not by the minimal userspace.
if [ ! -d "$overlay_root" ]; then
    mountpoint -q /sys/kernel/config 2>/dev/null || mount -t configfs none /sys/kernel/config 2>/dev/null || {
        log "configfs is unavailable; status LED profile was not applied"
        exit 0
    }
fi
[ -d "$overlay_root" ] || { log "device-tree overlay API is unavailable"; exit 0; }

# Do not overwrite a profile selected by an administrator or another boot
# component.  The profile can be removed with `atlantian-fpga remove` and the
# service masked before installing a different full bitstream.
if [ -e "$overlay_root/$instance" ]; then
    log "status LED profile is already active"
else
    # A Zynq PL is a single full configuration: applying this profile would
    # replace any other overlay's bitstream.  Leave administrator-selected
    # profiles untouched; the operator can mask this unit when composing a
    # larger design that includes these pins.
    for active in "$overlay_root"/*; do
        [ -d "$active" ] || continue
        [ "${active##*/}" = "$instance" ] && continue
        log "another FPGA profile (${active##*/}) is active; leaving PL unchanged"
        exit 0
    done
    if ! /usr/local/sbin/atlantian-fpga apply "$instance" \
        atlantian/status-leds/atlantian-status-leds.dtbo >/tmp/atlantian-fpga-status-leds.out 2>&1; then
        log "status LED profile could not be applied: $(cat /tmp/atlantian-fpga-status-leds.out 2>/dev/null)"
        rm -f /tmp/atlantian-fpga-status-leds.out
        exit 0
    fi
    rm -f /tmp/atlantian-fpga-status-leds.out
fi

# Explicitly force the safe state after binding.  The DT default-state is also
# off, but this protects against a stale output register in a prior design.
for led in d5 d6 d7 d8; do
    path="/sys/class/leds/atlantian:pl:$led/brightness"
    [ -w "$path" ] && printf '0\n' >"$path" || true
done
log "status LED profile ready; D5-D8 forced off"
exit 0
