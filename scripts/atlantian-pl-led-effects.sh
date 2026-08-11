#!/bin/sh
# Interactive effects console for the FPGA D5-D8 LED class devices.
# This is deliberately userspace-only: it never reprograms the FPGA.
set -eu

LED_ROOT=${ATLANTIAN_PL_LED_ROOT:-/sys/class/leds}
NAMES='d5 d6 d7 d8'
PIDS=''
RUN=1

led_path() { printf '%s/atlantian:pl:%s/brightness' "$LED_ROOT" "$1"; }
led_exists() { [ -e "$(led_path "$1")" ]; }
write_led() { [ -e "$(led_path "$1")" ] && printf '%s\n' "$2" >"$(led_path "$1")" || true; }
frame() {
  # Frame argument is a four-bit value, d5 is the most significant bit.
  v=$1
  for n in d5 d6 d7 d8; do
    bit=$((v / 8)); v=$((v % 8)); write_led "$n" "$bit"
  done
}
off() { frame 0; }
on() { frame 15; }
delay() { awk -v ms="${1:-150}" 'BEGIN { printf "%.3f", ms/1000 }'; }
cpu_load() {
  set -- $(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5+$6; exit}' /proc/stat)
  t=$1; i=$2; sleep 0.25
  set -- $(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5+$6; exit}' /proc/stat)
  dt=$(( $1 - t )); di=$(( $2 - i )); [ "$dt" -gt 0 ] && printf '%s' "$((100*(dt-di)/dt))" || printf '0'
}
cleanup() { RUN=0; off; }
trap cleanup INT TERM EXIT

for n in $NAMES; do led_exists "$n" || { echo "LED missing: $(led_path "$n")" >&2; exit 1; }; done

echo 'AtlANTian PL LED effects (D5-D8)'
echo '  1) off                 2) all on'
echo '  3) chase               4) ping-pong'
echo '  5) double blink        6) binary counter'
echo '  7) CPU load meter       8) load-driven pulse'
echo '  9) custom frames       0) exit'
printf 'Select effect: '; IFS= read -r choice || exit 0

case "$choice" in
1) off; read -r _ </dev/tty || true ;;
2) on; read -r _ </dev/tty || true ;;
3) while :; do for x in 1 2 4 8; do frame "$x"; sleep "$(delay 140)"; done; done ;;
4) while :; do for x in 1 2 4 8 4 2; do frame "$x"; sleep "$(delay 120)"; done; done ;;
5) while :; do frame 15; sleep "$(delay 90)"; off; sleep "$(delay 90)"; frame 15; sleep "$(delay 90)"; off; sleep "$(delay 650)"; done ;;
6) i=0; while :; do frame "$i"; i=$(( (i + 1) % 16 )); sleep "$(delay 180)"; done ;;
7) while :; do l=$(cpu_load); n=$(( (l * 15 + 50) / 100 )); frame "$n"; sleep 1; done ;;
8) while :; do l=$(cpu_load); d=$((900 - (l * 780 / 100))); frame 15; sleep "$(delay 90)"; off; sleep "$(delay "$d")"; done ;;
9) echo 'Enter hexadecimal 4-bit frames separated by spaces (e.g. 1 3 f 0):'; printf '> '; IFS= read -r seq || exit 0; while :; do for h in $seq; do case "$h" in [0-9]) frame "$h";; [a-fA-F]) frame "$(printf '%d' "0x$h")";; esac; sleep "$(delay 180)"; done; done ;;
0|'') exit 0 ;;
*) echo 'Unknown effect'; exit 2 ;;
esac
