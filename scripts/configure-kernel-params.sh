#!/bin/sh
# Ensure the kernel command line carries the parameters the stack needs, and
# say so when a reboot is what is still missing.
#
# Only for things that cannot be set at runtime. PSI is the whole reason this
# exists: the Pi kernel is built CONFIG_PSI=y with CONFIG_PSI_DEFAULT_DISABLED=y,
# so /proc/pressure and every cgroup's memory.pressure are absent until psi=1
# is on the command line - there is no sysfs or sysctl equivalent to write.
# Without it, the only memory-pressure evidence available is /proc/vmstat's
# counters, which are cumulative since boot and cannot show a rate.
#
# cmdline.txt is one space-separated line and a corrupted one is an unbootable
# Pi, so: nothing but the keys in KERNEL_PARAMS is ever touched, the rewrite is
# validated before it replaces anything, the original is backed up once, and
# the new file is written and synced beside the old one before the rename.
#
# Idempotent: re-runs print what is already set and touch nothing.
#
# `configure-kernel-params.sh remove` strips those keys again, for uninstall.

set -eu

. "$(dirname "$0")/lib.sh"

# key=value, one per line. A key already present with a different value is
# corrected; a key absent is appended. Nothing is ever deleted.
#
# zswap is a compressed cache in RAM in front of /var/swap: a page evicted from
# a cgroup is compressed and kept in memory, and only reaches the NVMe once the
# pool is full. It is compiled in but off (CONFIG_ZSWAP=y without
# CONFIG_ZSWAP_DEFAULT_ON), and this stack is exactly its case - the model
# services evict multi-GB working sets that then get faulted straight back in
# on the next request.
#
# The compressor is deliberately not set. CRYPTO_ZSTD and CRYPTO_LZ4 are
# modules on this kernel while zswap is built in, so zswap.compressor=zstd on
# the boot line is evaluated before the module exists and falls back to lzo
# without saying so. lzo is the built-in default and what actually runs.
#
# shrinker_enabled is not the kernel default and is the point of the exercise
# here: without it a full pool simply stops accepting, and it fills with the
# first pages to arrive - which on this box are the cold model weights nobody
# will ask for. The shrinker writes those back to disk and keeps the pool for
# pages with a future.
KERNEL_PARAMS='psi=1
zswap.enabled=1
zswap.max_pool_percent=20
zswap.shrinker_enabled=1'

find_cmdline() {
    for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# The tokens a Raspberry Pi will not boot without. Cheap insurance against a
# rewrite that lost the line rather than edited it.
line_is_bootable() {
    local line="$1"
    case "$line" in
        *root=*) ;;
        *) return 1 ;;
    esac
    case "$line" in
        *rootfstype=*) ;;
        *) return 1 ;;
    esac
    [ "$(printf '%s' "$line" | wc -l)" -eq 0 ]
}

# Echo $line with $key set to $value, in place if the key is already there.
set_param() {
    local line="$1"
    local key="$2"
    local value="$3"
    local out=""
    local found=""
    local token=""

    for token in $line; do
        case "$token" in
            "$key"=*)
                found=yes
                out="$out $key=$value"
                ;;
            *)
                out="$out $token"
                ;;
        esac
    done

    [ -n "$found" ] || out="$out $key=$value"

    printf '%s' "${out# }"
}

param_is_set() {
    local line="$1"
    local wanted="$2"
    local token=""

    for token in $line; do
        [ "$token" != "$wanted" ] || return 0
    done
    return 1
}

# Echo $line without the keys this script owns. Used by `make uninstall`, which
# strips exactly what was added rather than restoring the backup: another tool
# may have edited the same line since, and its parameters are not ours to drop.
drop_own_params() {
    local line="$1"
    local out=""
    local token=""
    local param=""
    local keep=""

    for token in $line; do
        keep=yes
        for param in $KERNEL_PARAMS; do
            [ "${token%%=*}" != "${param%%=*}" ] || keep=""
        done
        [ -z "$keep" ] || out="$out $token"
    done

    printf '%s' "${out# }"
}

main() {
    local cmdline=""
    if ! cmdline="$(find_cmdline)"; then
        log "No cmdline.txt under /boot (not a Raspberry Pi boot layout); skipping kernel parameters"
        return 0
    fi

    local original=""
    original="$(head -n1 "$cmdline")"
    [ -n "$original" ] || die "$cmdline is empty - refusing to touch it"

    local updated=""
    local pending=""
    local param=""

    if [ "${1:-}" = "remove" ]; then
        updated="$(drop_own_params "$original")"
        if [ "$updated" = "$original" ]; then
            log "No pi-pcloud kernel parameters in $cmdline; nothing to remove"
            return 0
        fi
        pending=" (removing$(printf ' %s' $KERNEL_PARAMS))"
    else
        updated="$original"
        for param in $KERNEL_PARAMS; do
            if param_is_set "$updated" "$param"; then
                continue
            fi
            pending="$pending $param"
            updated="$(set_param "$updated" "${param%%=*}" "${param#*=}")"
        done

        if [ -z "$pending" ]; then
            log "Kernel parameters already set:$(printf ' %s' $KERNEL_PARAMS)"
            return 0
        fi
    fi

    line_is_bootable "$updated" ||
        die "the rewritten kernel command line does not look bootable - leaving $cmdline alone"

    if [ ! -f "$cmdline.pi-pcloud.bak" ]; then
        sudo cp "$cmdline" "$cmdline.pi-pcloud.bak"
        log "Backed up original to $cmdline.pi-pcloud.bak"
    fi

    # Written into the same directory and synced before the rename, so a power
    # cut during this leaves either the old line or the new one, never half.
    local staged="$cmdline.pi-pcloud.new"
    printf '%s\n' "$updated" | sudo tee "$staged" >/dev/null
    sudo sync "$staged"
    sudo mv "$staged" "$cmdline"
    sudo sync "$(dirname "$cmdline")"

    log "Updated $cmdline:$pending"
    log "These take effect on the next reboot."
}

main "$@"
