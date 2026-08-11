#!/bin/sh
# User-facing NAND install entry point. Fresh destructive installs require the
# embedded payload to match the running SD release. A prepared NAND upgrade may
# carry an explicitly verified newer bundle path in the pending transaction.
set -eu

DEFAULT_BUNDLE=${ATLANTIAN_NAND_BUNDLE:-/usr/lib/atlantian/nand}
PENDING=/var/lib/atlantian/nand-install/pending
CORE=/usr/local/sbin/atlantian-nand-install-core

[ -x "$CORE" ] || { echo 'atlantian-nand-install: installer core is missing' >&2; exit 69; }

case "${1:-}" in
    --help|-h|--handoff)
        exec "$CORE" "$@"
        ;;
    --resume|--resume-auto)
        if [ -s "$PENDING" ]; then
            bundle=$(sed -n 's/^bundle=//p' "$PENDING" | head -n1)
            expected=$(sed -n 's/^release=//p' "$PENDING" | head -n1)
            if [ -n "$bundle" ]; then
                case "$bundle" in /var/cache/atlantian/nand-target/*/bundle) ;; *) echo 'atlantian-nand-install: unsafe pending bundle path' >&2; exit 65 ;; esac
                [ -s "$bundle/NAND-MANIFEST.json" ] || { echo "atlantian-nand-install: pending bundle disappeared: $bundle" >&2; exit 69; }
                target=$(jq -r '.release // empty' "$bundle/NAND-MANIFEST.json" 2>/dev/null || true)
                [ -n "$expected" ] && [ "$target" = "$expected" ] || { echo 'atlantian-nand-install: pending bundle/release identity mismatch' >&2; exit 65; }
                exec env ATLANTIAN_NAND_BUNDLE="$bundle" "$CORE" "$@"
            fi
        fi
        ;;
esac

BUNDLE=$DEFAULT_BUNDLE
[ -s "$BUNDLE/NAND-MANIFEST.json" ] || {
    echo "atlantian-nand-install: NAND payload is missing under $BUNDLE" >&2
    exit 69
}
running=$(cat /usr/lib/atlantian/version 2>/dev/null || true)
target=$(jq -r '.release // empty' "$BUNDLE/NAND-MANIFEST.json" 2>/dev/null || true)
[ -n "$running" ] && [ -n "$target" ] || {
    echo 'atlantian-nand-install: cannot determine running/payload release identity' >&2
    exit 65
}
[ "$running" = "$target" ] || {
    echo "atlantian-nand-install: embedded NAND payload $target does not match running AtlANTian $running" >&2
    echo 'For a NAND base update, boot NAND and run atlantian-sysupgrade to stage the target bundle on this recovery SD.' >&2
    exit 78
}

exec "$CORE" "$@"
