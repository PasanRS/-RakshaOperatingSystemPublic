#!/usr/bin/env bash
# Verify that the running kernel has a usable initramfs before shutdown.
# This is deliberately read-only: repair must be explicit and separately audited.
set -u

TAG="raksha-initramfs"
BOOT_DIR="${RAKSHA_BOOT_DIR:-/boot}"
MIN_BYTES="${RAKSHA_INITRAMFS_MIN_BYTES:-65536}"
kernel="$(uname -r)"

log() { printf '%s\n' "$*" | systemd-cat -t "$TAG" -p info 2>/dev/null || printf '%s\n' "$*"; }
fail() {
    local message="INITRAMFS PREFLIGHT FAILED: $*"
    printf '%s\n' "$message" | systemd-cat -t "$TAG" -p crit 2>/dev/null || printf '%s\n' "$message" >&2
    if command -v wall >/dev/null 2>&1; then
        printf '\n%s\n\n' "$message" | wall 2>/dev/null || true
    fi
    return 1
}

if [[ "$(id -u)" -ne 0 ]]; then
    fail "must run as root"
    exit 1
fi

if [[ ! -d "$BOOT_DIR" ]]; then
    fail "$BOOT_DIR is missing"
    exit 1
fi

initrd=""
for candidate in \
    "$BOOT_DIR/initrd.img-$kernel" \
    "$BOOT_DIR/initramfs-$kernel" \
    "$BOOT_DIR/initrd-$kernel"; do
    if [[ -f "$candidate" ]]; then
        initrd="$candidate"
        break
    fi
done

if [[ -z "$initrd" ]]; then
    fail "no initramfs found for running kernel $kernel"
    exit 1
fi

if [[ ! -s "$initrd" ]]; then
    fail "$initrd is empty"
    exit 1
fi

size="$(stat -c '%s' "$initrd" 2>/dev/null || printf '0')"
if [[ "$size" -lt "$MIN_BYTES" ]]; then
    fail "$initrd is only $size bytes"
    exit 1
fi

kernel_image=""
for candidate in "$BOOT_DIR/vmlinuz-$kernel" "$BOOT_DIR/kernel-$kernel"; do
    if [[ -f "$candidate" ]]; then
        kernel_image="$candidate"
        break
    fi
done
if [[ -z "$kernel_image" ]]; then
    fail "no kernel image found for running kernel $kernel"
    exit 1
fi

if command -v lsinitramfs >/dev/null 2>&1; then
    listing="$(mktemp)"
    trap 'rm -f "$listing"' EXIT
    if ! lsinitramfs "$initrd" >"$listing" 2>/dev/null; then
        fail "$initrd cannot be read by lsinitramfs"
        exit 1
    fi
    if ! rg -q '(^|/)init$' "$listing" 2>/dev/null && ! grep -Eq '(^|/)init$' "$listing"; then
        fail "$initrd has no init entry"
        exit 1
    fi
fi

log "INITRAMFS PREFLIGHT PASS: kernel=$kernel initramfs=$initrd bytes=$size"
exit 0
