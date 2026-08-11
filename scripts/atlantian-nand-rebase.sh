#!/bin/sh
# Capture persistent user/admin deltas from the real old OverlayFS view and
# replay them onto a fresh upper above a new immutable lower. Package-manager
# state itself always comes from the new base; only explicit package intent moves.
set -eu

usage() {
    cat <<'EOF'
Usage:
  atlantian-nand-rebase capture LOWER UPPER WORK SNAPSHOT
  atlantian-nand-rebase restore SNAPSHOT LOWER UPPER WORK TARGET_RELEASE
EOF
}

fatal() { echo "atlantian-nand-rebase: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fatal "missing required command: $1"; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
for c in mount umount mountpoint rsync chroot sort comm awk sed grep mktemp find install; do need "$c"; done

# Keep administrator/application state, not package payload namespaces. /usr/local
# is local-admin territory; /usr itself, /bin, /lib and package databases are not.
PERSIST_PATHS='etc root home usr/local opt srv var/local var/lib var/spool var/www'

varlib_rsync_args() {
    printf '%s\n' \
      '--exclude=apt/' \
      '--exclude=dpkg/' \
      '--exclude=systemd/' \
      '--exclude=ucf/' \
      '--exclude=initramfs-tools/' \
      '--exclude=atlantian/nand/reconcile-release' \
      '--exclude=atlantian/nand/rebase-intent/'
}

pkg_installed() {
    root=$1
    chroot "$root" dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 2>/dev/null \
      | awk '$1 ~ /^ii/ {print $2}' | LC_ALL=C sort -u
}
pkg_manual() { chroot "$1" apt-mark showmanual 2>/dev/null | LC_ALL=C sort -u; }
pkg_holds() { chroot "$1" apt-mark showhold 2>/dev/null | LC_ALL=C sort -u; }

capture_path() {
    lower=$1 merged=$2 out=$3 rel=$4
    src=$merged/$rel
    base=$lower/$rel
    dst=$out/delta/$rel

    # A whiteout can remove an entire persistent top-level directory. Record that
    # explicitly instead of returning early merely because the merged path is gone.
    if ! exists "$src"; then
        exists "$base" && printf '%s\n' "$rel" >>"$out/deleted.paths"
        return 0
    fi
    mkdir -p "$dst"

    set --
    if [ "$rel" = var/lib ]; then
        while IFS= read -r arg; do set -- "$@" "$arg"; done <<EOF_ARGS
$(varlib_rsync_args)
EOF_ARGS
    fi
    if [ -d "$base" ]; then
        rsync -aHAX --numeric-ids "$@" --compare-dest="$base/" "$src/" "$dst/"
        rsync -ani --delete "$@" "$src/" "$base/" \
          | sed -n 's/^\*deleting[[:space:]]*//p' \
          | sed "s#^#$rel/#" >>"$out/deleted.paths"
    else
        rsync -aHAX --numeric-ids "$@" "$src/" "$dst/"
    fi
}

capture() {
    lower=$1 upper=$2 work=$3 out=$4
    [ -d "$lower" ] || fatal "lower does not exist: $lower"
    [ -d "$upper" ] || fatal "upper does not exist: $upper"
    [ -d "$work" ] || fatal "workdir does not exist: $work"

    rm -rf "$out"
    mkdir -p "$out/delta"
    : >"$out/deleted.paths"

    merged=$(mktemp -d /run/atlantian-rebase-capture.XXXXXX)
    cleanup_capture() {
        set +e
        mountpoint -q "$merged" && umount "$merged"
        rmdir "$merged" 2>/dev/null || true
        set -e
    }
    trap cleanup_capture EXIT INT TERM HUP

    # Use the same standard lower/upper/work relationship as NAND boot. The
    # capture path itself performs only reads against this merged view; OverlayFS
    # interprets old whiteouts and opaque directories for us.
    mount -t overlay overlay -o "lowerdir=$lower,upperdir=$upper,workdir=$work" "$merged" \
      || fatal 'cannot assemble old merged filesystem for rebase capture'

    tmp=$(mktemp -d /run/atlantian-rebase-pkgs.XXXXXX)
    pkg_manual "$lower" >"$tmp/base.manual"
    pkg_manual "$merged" >"$tmp/merged.manual"
    comm -13 "$tmp/base.manual" "$tmp/merged.manual" >"$out/manual-extra.packages"
    pkg_holds "$lower" >"$tmp/base.holds"
    pkg_holds "$merged" >"$tmp/merged.holds"
    comm -13 "$tmp/base.holds" "$tmp/merged.holds" >"$out/user-holds.packages"
    pkg_installed "$merged" >"$out/installed.packages"
    rm -rf "$tmp"

    for rel in $PERSIST_PATHS; do capture_path "$lower" "$merged" "$out" "$rel"; done
    LC_ALL=C sort -u "$out/deleted.paths" -o "$out/deleted.paths"
    printf 'schema=1\nsource_release=%s\n' \
      "$(cat "$lower/usr/lib/atlantian/version" 2>/dev/null || printf unknown)" >"$out/METADATA"
    sync
    cleanup_capture
    trap - EXIT INT TERM HUP
}

safe_rel() {
    case "$1" in
        etc|etc/*|root|root/*|home|home/*|usr/local|usr/local/*|opt|opt/*|srv|srv/*|var/local|var/local/*|var/lib|var/lib/*|var/spool|var/spool/*|var/www|var/www/*) ;;
        *) fatal "unsafe path in rebase snapshot: $1" ;;
    esac
    case "/$1/" in *'/../'*|*'/./'*) fatal "unsafe traversal in rebase snapshot: $1" ;; esac
}

validate_pkg_file() {
    file=$1
    [ -f "$file" ] || return 0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        case "$pkg" in *[!A-Za-z0-9:+._-]*) fatal "unsafe package name in $file: $pkg" ;; esac
    done <"$file"
}

restore() {
    snap=$1 lower=$2 upper=$3 work=$4 target=$5
    [ -s "$snap/METADATA" ] || fatal "invalid rebase snapshot: $snap"
    [ -d "$snap/delta" ] || fatal "rebase delta is missing: $snap"
    [ -d "$lower" ] || fatal "new lower does not exist: $lower"
    mkdir -p "$upper" "$work"
    [ -z "$(find "$upper" -mindepth 1 -print -quit)" ] || fatal "restore upper is not empty: $upper"
    [ -z "$(find "$work" -mindepth 1 -print -quit)" ] || fatal "restore workdir is not empty: $work"
    validate_pkg_file "$snap/manual-extra.packages"
    validate_pkg_file "$snap/user-holds.packages"

    merged=$(mktemp -d /run/atlantian-rebase-restore.XXXXXX)
    cleanup_restore() {
        set +e
        mountpoint -q "$merged" && umount "$merged"
        rmdir "$merged" 2>/dev/null || true
        set -e
    }
    trap cleanup_restore EXIT INT TERM HUP
    mount -t overlay overlay -o "lowerdir=$lower,upperdir=$upper,workdir=$work" "$merged" \
      || fatal 'cannot assemble new writable filesystem for rebase restore'

    if [ -s "$snap/deleted.paths" ]; then
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            safe_rel "$rel"
            rm -rf -- "$merged/$rel"
        done <"$snap/deleted.paths"
    fi
    rsync -aHAX --numeric-ids "$snap/delta/" "$merged/"

    state=$merged/var/lib/atlantian/nand
    rm -rf "$state/rebase-intent"
    mkdir -p "$state/rebase-intent"
    install -m 0644 "$snap/manual-extra.packages" "$state/rebase-intent/manual-extra.packages"
    install -m 0644 "$snap/user-holds.packages" "$state/rebase-intent/user-holds.packages"
    printf '%s\n' "$target" >"$state/reconcile-release"
    sync
    cleanup_restore
    trap - EXIT INT TERM HUP
}

cmd=${1:-}
case "$cmd" in
    capture) [ $# -eq 5 ] || { usage >&2; exit 64; }; capture "$2" "$3" "$4" "$5" ;;
    restore) [ $# -eq 6 ] || { usage >&2; exit 64; }; restore "$2" "$3" "$4" "$5" "$6" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 64 ;;
esac
