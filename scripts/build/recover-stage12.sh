#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Raksha OS — Stage 12 Recovery: Assemble ISO from squashfs
# Bedrock-compatible: avoids chroot, extracts kernel from .deb
# ═══════════════════════════════════════════════════════════
set -euo pipefail

WORK_DIR="${WORK_DIR:-/home/ravan/raksha-build}"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${REPO_DIR}/builds"
ISO_FILE="raksha-os-1.0.0-amd64.iso"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[RECOVER]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$(id -u)" -ne 0 ] && err "Run as root: sudo bash $0"

SQUASHFS="${WORK_DIR}/iso/live/filesystem.squashfs"
[ -f "${SQUASHFS}" ] || err "Squashfs not found: ${SQUASHFS}"
log "Squashfs: $(du -sh ${SQUASHFS} | cut -f1) ✓"

TMPROOT="/tmp/raksha-kernel-$$"
mkdir -p "${TMPROOT}"
trap "rm -rf ${TMPROOT}" EXIT

# ══════════════════════════════════════════════════════
# STRATEGY 1: Find kernel already in squashfs /boot
# ══════════════════════════════════════════════════════
log "Strategy 1: Scanning squashfs for kernel files..."
# Use find inside unsquashfs pseudo-device (list mode — no full extract)
VMLINUZ_PATH=$(unsquashfs -l "${SQUASHFS}" 2>/dev/null \
    | grep -oP 'squashfs-root/boot/vmlinuz-\S+' | head -1 || true)
INITRD_PATH=$(unsquashfs -l "${SQUASHFS}" 2>/dev/null \
    | grep -oP 'squashfs-root/boot/initrd.img-\S+' | head -1 || true)

if [ -n "${VMLINUZ_PATH}" ] && [ -n "${INITRD_PATH}" ]; then
    log "  Found in squashfs — extracting boot/ only..."
    unsquashfs -d "${TMPROOT}/squash" "${SQUASHFS}" boot 2>&1 | tail -2

    VMLINUZ=$(find "${TMPROOT}/squash/boot" -name "vmlinuz-*" | head -1)
    INITRD=$(find  "${TMPROOT}/squash/boot" -name "initrd.img-*" | head -1)
    log "  ✓ vmlinuz: $(basename ${VMLINUZ})"
    log "  ✓ initrd : $(basename ${INITRD})"
else
    warn "  No kernel in squashfs (common under Bedrock Linux chroot)"

    # ══════════════════════════════════════════════════
    # STRATEGY 2: Download kernel .deb, extract directly
    # No chroot, no post-install scripts — Bedrock safe
    # ══════════════════════════════════════════════════
    log "Strategy 2: Downloading kernel .deb and extracting directly..."

    DEBS_DIR="${TMPROOT}/debs"
    EXTRACT_DIR="${TMPROOT}/kernel-extract"
    INITRD_DIR="${TMPROOT}/initrd-extract"
    mkdir -p "${DEBS_DIR}" "${EXTRACT_DIR}" "${INITRD_DIR}"

    # Download kernel package (uses rootfs apt cache if available, else downloads fresh)
    CACHED_DEB=$(find "${WORK_DIR}/rootfs/var/cache/apt/archives" \
        -name "linux-image-*-amd64_*.deb" 2>/dev/null | head -1 || true)

    if [ -n "${CACHED_DEB}" ]; then
        log "  Using cached .deb: $(basename ${CACHED_DEB})"
        cp "${CACHED_DEB}" "${DEBS_DIR}/"
    else
        log "  Downloading linux-image-amd64 from Debian mirrors..."
        # Get the exact package URL from apt
        apt-get download linux-image-amd64 --print-uris 2>/dev/null \
            | awk '{print $1}' | tr -d "'" > "${TMPROOT}/kernel-url.txt" || true

        # Direct apt download into temp dir
        cd "${DEBS_DIR}"
        apt-get download linux-image-amd64 2>&1 | tail -3 || \
        apt-get download linux-image-amd64-signed 2>&1 | tail -3 || true
        cd -

        # Also try getting initramfs tools separately
        cd "${DEBS_DIR}"
        apt-get download initramfs-tools 2>/dev/null | tail -2 || true
        cd -
    fi

    DEB=$(find "${DEBS_DIR}" -name "linux-image-*.deb" | head -1)
    [ -z "${DEB}" ] && err "Could not find or download kernel .deb"
    log "  Extracting: $(basename ${DEB})"

    # Extract .deb without any scripts (Bedrock-safe)
    dpkg-deb -x "${DEB}" "${EXTRACT_DIR}"

    VMLINUZ=$(find "${EXTRACT_DIR}" -name "vmlinuz-*" | head -1)
    [ -z "${VMLINUZ}" ] && err "vmlinuz not found in .deb — check: ls ${EXTRACT_DIR}/boot/"

    log "  ✓ vmlinuz: $(basename ${VMLINUZ})"

    # ── Build initrd using dracut or mkinitramfs from HOST ──
    # (Bedrock: run host tools directly, not inside chroot)
    KERNEL_VER=$(basename "${VMLINUZ}" | sed 's/vmlinuz-//')
    log "  Building initrd for kernel: ${KERNEL_VER}"

    INITRD="${TMPROOT}/initrd.img-${KERNEL_VER}"

    if command -v mkinitramfs &>/dev/null; then
        # Install kernel modules from .deb into a temp prefix
        # Then generate initrd against it
        mkinitramfs -o "${INITRD}" "${KERNEL_VER}" 2>&1 | tail -5 || {
            warn "  mkinitramfs failed — trying with extracted modules"
            # Copy modules from extracted deb
            mkdir -p /tmp/raksha-modules-$$
            cp -r "${EXTRACT_DIR}/lib" /tmp/raksha-modules-$$/
            TMPDIR="${TMPROOT}" mkinitramfs \
                -d "${EXTRACT_DIR}/etc/initramfs-tools" \
                -o "${INITRD}" "${KERNEL_VER}" 2>&1 | tail -5 || true
            rm -rf /tmp/raksha-modules-$$
        }
    elif command -v dracut &>/dev/null; then
        dracut --force --kver "${KERNEL_VER}" "${INITRD}" 2>&1 | tail -5
    else
        warn "  Neither mkinitramfs nor dracut found"
        warn "  Trying to extract initrd from live Bedrock system..."
        # Use host's running kernel initrd as a fallback
        HOST_INITRD=$(find /boot -name "initrd.img-*" | sort -V | tail -1)
        if [ -n "${HOST_INITRD}" ]; then
            cp "${HOST_INITRD}" "${INITRD}"
            warn "  Used host initrd: $(basename ${HOST_INITRD})"
            warn "  This may not boot perfectly — rebuild if issues occur"
        else
            err "No initrd available. Install initramfs-tools: apt install initramfs-tools"
        fi
    fi

    log "  ✓ initrd: $(du -sh ${INITRD} | cut -f1)"
fi

# ══════════════════════════════════════════════════════
# COPY KERNEL TO ISO BOOT DIR
# ══════════════════════════════════════════════════════
log "Copying kernel files to ISO boot directory..."
mkdir -p "${WORK_DIR}/iso/boot/grub"
cp "${VMLINUZ}" "${WORK_DIR}/iso/boot/vmlinuz"
cp "${INITRD}"  "${WORK_DIR}/iso/boot/initrd"
log "  ✓ vmlinuz → iso/boot/vmlinuz ($(du -sh ${WORK_DIR}/iso/boot/vmlinuz | cut -f1))"
log "  ✓ initrd  → iso/boot/initrd  ($(du -sh ${WORK_DIR}/iso/boot/initrd | cut -f1))"

# ══════════════════════════════════════════════════════
# GRUB CONFIG
# ══════════════════════════════════════════════════════
log "Writing GRUB config..."
cat > "${WORK_DIR}/iso/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=10

if loadfont /boot/grub/fonts/unicode.pf2; then
  set gfxmode=auto
  insmod all_video
  insmod gfxterm
  terminal_output gfxterm
fi

menuentry "Install Raksha OS" --class raksha --class linux {
  linux /boot/vmlinuz boot=live components splash quiet \
        live-config.hostname=raksha \
        live-config.username=ravan \
        live-config.password=raksha \
        live-config.autologin=true
  initrd /boot/initrd
}

menuentry "Raksha OS Live (Try without installing)" --class raksha {
  linux /boot/vmlinuz boot=live components splash quiet
  initrd /boot/initrd
}

menuentry "Raksha OS (Safe Graphics / nomodeset)" --class raksha {
  linux /boot/vmlinuz boot=live components splash quiet nomodeset
  initrd /boot/initrd
}

menuentry "Raksha OS (Debug Mode)" --class raksha {
  linux /boot/vmlinuz boot=live components debug
  initrd /boot/initrd
}
EOF
log "  ✓ GRUB config written"

# ══════════════════════════════════════════════════════
# ASSEMBLE FINAL ISO
# ══════════════════════════════════════════════════════
log "Assembling final ISO..."
mkdir -p "${OUTPUT_DIR}"
grub-mkrescue \
    -o "${OUTPUT_DIR}/${ISO_FILE}" \
    "${WORK_DIR}/iso" \
    --fonts="" --locales="" --themes="" \
    2>&1 | tail -5

ISO_SIZE=$(du -sh "${OUTPUT_DIR}/${ISO_FILE}" | cut -f1)
SQUASH_SIZE=$(du -sh "${SQUASHFS}" | cut -f1)

echo ""
echo "══════════════════════════════════════════════════════"
echo "  ✅  RAKSHA OS ISO COMPLETE"
echo "  File    : ${OUTPUT_DIR}/${ISO_FILE}"
echo "  Size    : ${ISO_SIZE}"
echo "  Squashfs: ${SQUASH_SIZE}"
echo ""
echo "  Flash to USB:"
echo "    sudo dd if=${OUTPUT_DIR}/${ISO_FILE} of=/dev/sdX bs=4M status=progress"
echo ""
echo "  Test in QEMU (8GB RAM, KVM):"
echo "    qemu-system-x86_64 -m 8G -enable-kvm \\"
echo "      -cdrom ${OUTPUT_DIR}/${ISO_FILE} -boot d"
echo "══════════════════════════════════════════════════════"
