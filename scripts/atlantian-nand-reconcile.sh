#!/bin/sh
# Finish a clean NAND upper rebase after the new immutable base first boots.
# The new lower owns dpkg state; only live same-major updates and saved user
# package intent are written into the fresh upper.
set -eu

MARKER=/var/lib/atlantian/nand/reconcile-release
INTENT=/var/lib/atlantian/nand/rebase-intent
[ -s "$MARKER" ] || exit 0
[ -r /run/atlantian/storage-edition ] && [ "$(cat /run/atlantian/storage-edition)" = nand ] || exit 0

target=$(head -n1 "$MARKER")
current=$(cat /usr/lib/atlantian/version 2>/dev/null || true)
[ -n "$target" ] && [ "$current" = "$target" ] || {
    echo "AtlANTian NAND rebase deferred: base is ${current:-unknown}, marker expects ${target:-unknown}" >&2
    exit 75
}

valid_pkg() {
    case "$1" in ''|*[!A-Za-z0-9:+._-]*) return 1 ;; *) return 0 ;; esac
}

install_manual_extras() {
    file=$INTENT/manual-extra.packages
    [ -s "$file" ] || return 0
    set --
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        valid_pkg "$pkg" || { echo "invalid package intent: $pkg" >&2; exit 65; }
        set -- "$@" "$pkg"
    done <"$file"
    [ $# -eq 0 ] || apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' install -y "$@"
}

restore_holds() {
    file=$INTENT/user-holds.packages
    [ -s "$file" ] || return 0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        valid_pkg "$pkg" || { echo "invalid package hold intent: $pkg" >&2; exit 65; }
        if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii'; then
            apt-mark hold "$pkg" >/dev/null
        fi
    done <"$file"
}

echo "Reconciling rebased NAND writable layer with immutable base $target..."
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Reapply holds that already exist in the fresh base before moving it to the
# current same-major Debian package level. This avoids regressing a board that
# had received security/package updates newer than the factory Snapshot.
restore_holds
apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' upgrade -y
install_manual_extras
apt-get -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' -f install -y
# Holds on manually reinstalled packages can only be applied after they exist.
restore_holds

audit=$(dpkg --audit 2>&1 || true)
[ -z "$audit" ] || { printf '%s\n' "$audit" >&2; exit 1; }
rm -rf "$INTENT"
rm -f "$MARKER"
sync
echo 'Active NAND writable layer rebase is complete.'
