#!/usr/bin/env bash
# Apply small audited Zynq NAND deltas to the pinned U-Boot tree.
set -euo pipefail
SRC=${1:?usage: patch-uboot-nand.sh UBOOT_SOURCE [--spl-loader]}
MODE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
FILE=$SRC/drivers/mtd/nand/raw/zynq_nand.c
KCONFIG=$SRC/drivers/mtd/nand/raw/Kconfig
WAIT_INC=$HERE/uboot-zynq-spl-wait.inc
READER_INC=$HERE/uboot-zynq-spl-reader.inc
for f in "$FILE" "$KCONFIG" "$WAIT_INC" "$READER_INC"; do
  [[ -f $f ]] || { echo "missing $f" >&2; exit 2; }
done

# The dedicated xPL fragments are intentionally independent of U-Boot's timer
# and runtime NAND discovery. Keep that architectural boundary fail-closed.
if grep -Eq '\b(udelay|ndelay|get_timer|timer_get_us)[[:space:]]*\(' "$WAIT_INC" "$READER_INC"; then
  echo 'AtlANTian SPL NAND fragments must not use timer-based delay APIs' >&2
  exit 2
fi
if grep -Eq '\bnand_scan_ident[[:space:]]*\(' "$WAIT_INC" "$READER_INC"; then
  echo 'AtlANTian SPL NAND fragments must not invoke runtime NAND discovery' >&2
  exit 2
fi

python3 - "$FILE" "$KCONFIG" "$WAIT_INC" "$READER_INC" "$MODE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]); kconfig = Path(sys.argv[2])
wait_inc = Path(sys.argv[3]).read_text().rstrip() + '\n\n'
reader_inc = Path(sys.argv[4]).read_text().rstrip() + '\n'
mode = sys.argv[5]
text = path.read_text()

forced = '\tnand_chip->bbt_options = NAND_BBT_USE_FLASH;\n'
marker = '\t/* AtlANTian: keep NAND probing read-only; use factory bad-block markers. */\n'
if forced in text:
    text = text.replace(forced, marker, 1)
elif marker not in text:
    raise SystemExit('U-Boot Zynq NAND BBT policy no longer matches expected source')

pair = '\t\t/* Use the BBT pattern descriptors */\n\t\tnand_chip->bbt_td = &bbt_main_descr;\n\t\tnand_chip->bbt_md = &bbt_mirror_descr;\n'
pair_marker = '\t\t/* AtlANTian: preserve factory OOB bad-block markers; no flash BBT. */\n'
if pair in text:
    text = text.replace(pair, pair_marker, 1)
elif pair_marker not in text:
    raise SystemExit('U-Boot on-die BBT descriptor policy no longer matches expected source')

if mode == '--spl-loader':
    # Put the timerless helper before the controller's own ECC wait as well as
    # before command R/B waits, so no xPL NAND initialization path needs udelay().
    ecc_anchor = '/*\n * zynq_nand_waitfor_ecc_completion - Wait for ECC completion\n'
    if 'static int atln_spl_wait_ready' not in text:
        if text.count(ecc_anchor) != 1:
            raise SystemExit('cannot locate unique Zynq NAND ECC-wait anchor')
        text = text.replace(ecc_anchor, wait_inc + ecc_anchor, 1)

    ecc_delay_old = '\t\ttimeout--;\n\t\tudelay(1);\n'
    ecc_delay_new = '''\t\ttimeout--;\n#if defined(CONFIG_XPL_BUILD)\n\t\tatln_spl_short_delay();\n#else\n\t\tudelay(1);\n#endif\n'''
    if ecc_delay_new not in text:
        if text.count(ecc_delay_old) != 1:
            raise SystemExit('cannot locate unique Zynq NAND ECC delay anchor')
        text = text.replace(ecc_delay_old, ecc_delay_new, 1)

    # Upstream ndelay(100) is implemented through udelay(), so replace the tWB
    # delay too. The finite CPU loop is intentionally conservative and tiny
    # compared with a NAND page read.
    cmd_delay_old = '\tndelay(100);\n\n\tif ((command == NAND_CMD_READ0) ||\n'
    cmd_delay_new = '''#if defined(CONFIG_XPL_BUILD)\n\tatln_spl_short_delay();\n#else\n\tndelay(100);\n#endif\n\n\tif ((command == NAND_CMD_READ0) ||\n'''
    if cmd_delay_new not in text:
        if text.count(cmd_delay_old) != 1:
            raise SystemExit('cannot locate unique Zynq NAND command delay anchor')
        text = text.replace(cmd_delay_old, cmd_delay_new, 1)

    wait_old = '''\tif ((command == NAND_CMD_READ0) ||\n\t    (command == NAND_CMD_RESET) ||\n\t    (command == NAND_CMD_PARAM) ||\n\t    (command == NAND_CMD_GET_FEATURES))\n\t\t/* wait until command is processed */\n\t\tnand_wait_ready(mtd);\n'''
    wait_new = '''\tif ((command == NAND_CMD_READ0) ||\n\t    (command == NAND_CMD_RESET) ||\n\t    (command == NAND_CMD_PARAM) ||\n\t    (command == NAND_CMD_GET_FEATURES)) {\n\t\t/* wait until command is processed */\n#if defined(CONFIG_XPL_BUILD)\n\t\tatln_spl_wait_ready(mtd);\n#else\n\t\tnand_wait_ready(mtd);\n#endif\n\t}\n'''
    if wait_new not in text:
        if text.count(wait_old) != 1:
            raise SystemExit('cannot locate unique Zynq NAND ready-wait anchor')
        text = text.replace(wait_old, wait_new, 1)

    board_old = '''void board_nand_init(void)\n{\n\tstruct udevice *dev;\n\tint ret;\n\n\tret = uclass_get_device_by_driver(UCLASS_MTD,\n\t\t\t\t\t  DM_DRIVER_GET(zynq_nand), &dev);\n\tif (ret && ret != -ENODEV)\n\t\tpr_err("Failed to initialize %s. (error %d)\\n", dev->name, ret);\n}\n'''
    if 'AtlANTian Zynq SPL NAND reader.' not in text:
        if text.count(board_old) != 1:
            raise SystemExit('cannot locate unique board_nand_init anchor')
        text = text.replace(board_old, reader_inc, 1)

path.write_text(text)

# Pull the raw NAND pieces needed by common/spl/spl_nand.c and the dedicated
# Zynq xPL reader into the SPL link. Runtime U-Boot still uses the normal DM path.
ktext = kconfig.read_text()
anchor = '''\tselect SPL_SYS_NAND_SELF_INIT
\tselect SYS_NAND_SELF_INIT
\tselect DM_MTD
'''
required = '''\tselect SPL_SYS_NAND_SELF_INIT
\tselect SYS_NAND_SELF_INIT
\tselect SPL_MTD
\tselect SPL_NAND_DRIVERS
\tselect SPL_NAND_BASE
\tselect SPL_NAND_IDENT
\tselect SPL_NAND_INIT
\tselect SPL_NAND_ECC
\tselect DM_MTD
'''
if required not in ktext:
    if anchor not in ktext:
        raise SystemExit('U-Boot Zynq NAND Kconfig no longer matches expected source')
    ktext = ktext.replace(anchor, required, 1)
kconfig.write_text(ktext)
PY

grep -Fq 'AtlANTian: keep NAND probing read-only' "$FILE"
grep -Fq 'AtlANTian: preserve factory OOB bad-block markers' "$FILE"
! grep -Fq 'nand_chip->bbt_options = NAND_BBT_USE_FLASH;' "$FILE"
grep -Fq 'select SPL_NAND_INIT' "$KCONFIG"
grep -Fq 'select SPL_MTD' "$KCONFIG"
if [[ $MODE == --spl-loader ]]; then
  grep -Fq 'AtlANTian Zynq SPL NAND reader.' "$FILE"
  grep -Fq 'static int atln_spl_wait_ready' "$FILE"
  grep -Fq 'atln_spl_short_delay();' "$FILE"
  grep -Fq 'Micron 2c:da on-die ECC ready' "$FILE"
  grep -Fq 'factory-bad block' "$FILE"
fi
