#!/bin/sh
# Select either the exact embedded payload or a newer verified payload prepared
# on the recovery SD by `atlantian-sysupgrade` while running NAND.
set -eu

DEFAULT_BUNDLE=${ATLANTIAN_NAND_BUNDLE:-/usr/lib/atlantian/nand}
PREPARED=/var/lib/atlantian/nand-target.env
CORE=/usr/local/sbin/atlantian-nand-upgrade-core

[ -x "$CORE" ] || { echo 'atlantian-nand-upgrade: upgrade core is missing' >&2; exit 69; }
BUNDLE=$DEFAULT_BUNDLE
prepared=no
if [ -s "$PREPARED" ]; then
    path=$(sed -n 's/^bundle=//p' "$PREPARED" | head -n1)
    expected=$(sed -n 's/^target=//p' "$PREPARED" | head -n1)
    case "$path" in /var/cache/atlantian/nand-target/*/bundle) ;; *) echo 'atlantian-nand-upgrade: unsafe prepared bundle path' >&2; exit 65 ;; esac
    [ -n "$expected" ] || { echo 'atlantian-nand-upgrade: prepared target identity is missing' >&2; exit 65; }
    BUNDLE=$path
    prepared=yes
fi

[ -s "$BUNDLE/NAND-MANIFEST.json" ] || {
    echo "atlantian-nand-upgrade: NAND payload is missing under $BUNDLE" >&2
    exit 69
}
target=$(jq -r '.release // empty' "$BUNDLE/NAND-MANIFEST.json" 2>/dev/null || true)
[ -n "$target" ] || { echo 'atlantian-nand-upgrade: cannot determine payload release identity' >&2; exit 65; }

if [ "$prepared" = yes ]; then
    [ "$target" = "$expected" ] || { echo "atlantian-nand-upgrade: prepared payload is $target, marker expects $expected" >&2; exit 65; }
else
    running=$(cat /usr/lib/atlantian/version 2>/dev/null || true)
    [ -n "$running" ] || { echo 'atlantian-nand-upgrade: cannot determine running release identity' >&2; exit 65; }
    [ "$running" = "$target" ] || {
        echo "atlantian-nand-upgrade: embedded NAND payload $target does not match running AtlANTian $running" >&2
        echo 'From NAND, run atlantian-sysupgrade to stage the target bundle on this recovery card.' >&2
        exit 78
    }
fi

exec env ATLANTIAN_NAND_BUNDLE="$BUNDLE" "$CORE" "$@"
