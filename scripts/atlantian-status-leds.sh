#!/bin/sh
# AtlANTian board-status service for the D3 status LED.
# No GPIO ABI is used here: DeviceTree has already safely bound MIO37/MIO38
# to named LED-class devices.
set -eu

red=/sys/class/leds/atlantian:red:status/brightness
green=/sys/class/leds/atlantian:green:activity/brightness
lock=/run/atlantian-update-leds.lock

[ -e "$red" ] && [ -e "$green" ] || exit 0
[ -e "$lock" ] && exit 0

off() { printf '0\n' >"$1"; }
on()  { printf '1\n' >"$1"; }
pulse() { on "$1"; sleep "$2"; off "$1"; }

# The aggregate 'cpu' line already covers both Cortex-A9 cores. The fields
# used below are total jiffies and idle+iowait jiffies.
cpu_sample() {
  set -- $(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5+$6; exit}' /proc/stat)
  printf '%s %s\n' "$1" "$2"
}
mmc_sample() {
  # Completed reads and writes in /sys/block/<dev>/stat, not filesystem cache.
  set -- $(cat /sys/block/mmcblk0/stat 2>/dev/null || printf '0 0 0 0 0 0 0')
  printf '%s %s\n' "${1:-0}" "${5:-0}"
}

set -- $(cpu_sample); old_total=$1; old_idle=$2
set -- $(mmc_sample); old_read=$1; old_write=$2
off "$red"; off "$green"

while :; do
  [ -e "$lock" ] && exit 0
  set -- $(cpu_sample); total=$1; idle=$2
  dt=$((total - old_total)); di=$((idle - old_idle))
  old_total=$total; old_idle=$idle
  if [ "$dt" -gt 0 ]; then
    load=$(( (100 * (dt - di)) / dt ))
  else
    load=0
  fi

  # Consume SD activity since the last sample; each observation is a visible
  # but short pulse and costs no disk I/O itself.
  set -- $(mmc_sample); reads=$1; writes=$2
  if [ "$reads" != "$old_read" ] || [ "$writes" != "$old_write" ]; then
    # Keep this synchronous. It is only 35 ms and avoids leaving competing
    # background writers behind during a sustained SD transfer.
    pulse "$green" 0.035
  fi
  old_read=$reads; old_write=$writes

  # Human-style double beat: 80 ms on, 120 ms gap, 80 ms on. Inter-pair pause
  # is 2.8 s at idle and falls linearly to 0.35 s at 100% aggregate load.
  pulse "$red" 0.08
  sleep 0.12
  pulse "$red" 0.08
  pause_ms=$((2800 - (2450 * load / 100)))
  sleep "$(awk "BEGIN { printf \"%.3f\", $pause_ms / 1000 }")"
done
