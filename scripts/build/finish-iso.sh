#!/bin/bash
# Raksha OS — Final ISO Assembly (Stage 12 only)
# Runs interactively so you can see every step
set -euo pipefail

ISO_OUT="/home/ravan/Raksha-OS-Core/builds/raksha-os-1.0.0-amd64.iso"
ISO_DIR="/home/ravan/raksha-build/iso"
TMPROOT="/tmp/raksha-final-$$"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Raksha OS — Final ISO Assembly                ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

[ "$(id -u)" -ne 0 ] && echo "Run as root: sudo bash $0" && exit 1
[ -f "${ISO_DIR}/live/filesystem.squashfs" ] || \
  { echo "ERROR: squashfs not found at ${ISO_DIR}/live/filesystem.squashfs"; exit 1; }

echo "[✓] Squashfs found: $(du -sh ${ISO_DIR}/live/filesystem.squashfs | cut -f1)"
echo ""

# ── STEP 1: Get vmlinuz ──────────────────────────────────────────────
echo "━━━ STEP 1: Getting kernel ━━━"
mkdir -p "${TMPROOT}"

VMLINUZ=$(find /tmp -name "vmlinuz-6.12*" 2>/dev/null | head -1)

if [ -n "${VMLINUZ}" ]; then
    echo "[✓] Using cached vmlinuz: ${VMLINUZ}"
else
    echo "    Downloading linux-image-6.12.95+deb13-amd64 (108MB)..."
    mkdir -p "${TMPROOT}/deb" "${TMPROOT}/extract"
    cd "${TMPROOT}/deb"
    apt-get download linux-image-6.12.95+deb13-amd64
    echo "    Extracting..."
    dpkg-deb -x "${TMPROOT}/deb/linux-image-6.12.95+deb13-amd64"*.deb "${TMPROOT}/extract"
    VMLINUZ=$(find "${TMPROOT}/extract/boot" -name "vmlinuz-*" | head -1)
    cd /
fi

KVER=$(basename "${VMLINUZ}" | sed 's/vmlinuz-//')
echo "[✓] Kernel: ${KVER}"
echo ""

# ── STEP 2: Copy vmlinuz to ISO boot dir ────────────────────────────
echo "━━━ STEP 2: Copying vmlinuz ━━━"
mkdir -p "${ISO_DIR}/boot"
cp -v "${VMLINUZ}" "${ISO_DIR}/boot/vmlinuz"
echo "[✓] Done: $(ls -lh ${ISO_DIR}/boot/vmlinuz)"
echo ""

# ── STEP 3: Build initrd ────────────────────────────────────────────
echo "━━━ STEP 3: Building initrd (2-4 min, verbose) ━━━"

# Check if kernel modules exist on host for this version
if [ -d "/lib/modules/${KVER}" ]; then
    echo "    Using host kernel modules for ${KVER}"
    mkinitramfs -v -o "${ISO_DIR}/boot/initrd" "${KVER}" 2>&1
else
    echo "    Kernel modules not on host — using live-boot generic initrd approach"
    # Install kernel modules from our extracted deb
    mkdir -p "${TMPROOT}/modules"
    dpkg-deb -x "${TMPROOT}/deb/linux-image-6.12.95+deb13-amd64"*.deb \
        "${TMPROOT}/modules" 2>/dev/null || true

    # Copy modules to /lib/modules temporarily
    if [ -d "${TMPROOT}/modules/lib/modules" ]; then
        cp -r "${TMPROOT}/modules/lib/modules/${KVER}" "/lib/modules/${KVER}" 2>/dev/null || true
        depmod "${KVER}" 2>/dev/null || true
    fi

    # Try mkinitramfs with these modules
    mkinitramfs -v -o "${ISO_DIR}/boot/initrd" "${KVER}" 2>&1 || {
        echo "    mkinitramfs failed — using host initrd as fallback"
        HOST_INITRD=$(find /boot -name "initrd.img-*" 2>/dev/null | sort -V | tail -1)
        if [ -n "${HOST_INITRD}" ]; then
            cp -v "${HOST_INITRD}" "${ISO_DIR}/boot/initrd"
            echo "[!] WARNING: Using host initrd ($(basename ${HOST_INITRD}))"
            echo "    The ISO may not boot if kernel versions differ significantly."
            echo "    Test in QEMU first before writing to USB."
        else
            echo "ERROR: Cannot build initrd. Install initramfs-tools: apt install initramfs-tools"
            exit 1
        fi
    }
fi

echo "[✓] initrd: $(ls -lh ${ISO_DIR}/boot/initrd)"
echo ""

# ── STEP 4: Write GRUB config ────────────────────────────────────────
echo "━━━ STEP 4: Writing GRUB config ━━━"
mkdir -p "${ISO_DIR}/boot/grub"
cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'EOF'
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
  linux /boot/vmlinuz boot=live components quiet nomodeset
  initrd /boot/initrd
}

menuentry "Raksha OS (Debug Mode)" --class raksha {
  linux /boot/vmlinuz boot=live components debug
  initrd /boot/initrd
}
EOF
echo "[✓] GRUB config written"
echo ""

# ── STEP 5: Assemble ISO ─────────────────────────────────────────────
echo "━━━ STEP 5: Assembling ISO with grub-mkrescue (3-5 min) ━━━"
mkdir -p "$(dirname ${ISO_OUT})"

# Remove old stub ISO if it's tiny (< 500MB = definitely not real)
if [ -f "${ISO_OUT}" ]; then
    SIZE=$(du -BM "${ISO_OUT}" | cut -f1 | tr -d 'M')
    [ "${SIZE}" -lt 500 ] && { echo "    Removing old stub ISO (${SIZE}MB)"; rm "${ISO_OUT}"; }
fi

grub-mkrescue \
    -o "${ISO_OUT}" \
    "${ISO_DIR}" \
    --fonts="" --locales="" --themes="" \
    2>&1

echo ""
ISO_SIZE=$(du -sh "${ISO_OUT}" | cut -f1)
echo "╔══════════════════════════════════════════════════╗"
echo "║   ✅  RAKSHA OS ISO COMPLETE                    ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  File    : ${ISO_OUT}"
echo "║  Size    : ${ISO_SIZE}"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Flash to USB:                                  ║"
echo "║  sudo dd if=${ISO_OUT} \\"
echo "║    of=/dev/sdX bs=4M status=progress            ║"
echo "║                                                  ║"
echo "║  Test in QEMU:                                  ║"
echo "║  qemu-system-x86_64 -m 8G -enable-kvm \\        ║"
echo "║    -cdrom ${ISO_OUT} -boot d   ║"
echo "╚══════════════════════════════════════════════════╝"

# Cleanup
rm -rf "${TMPROOT}"
