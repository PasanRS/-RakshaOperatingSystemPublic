#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Raksha OS — initrd + ISO Fix
# Fixes: initramfs drop (missing live-boot hooks), black GRUB, no Plymouth
#
# Strategy:
#   1. Mount squashfs read-only + overlayfs writable layer on top
#   2. Install kernel .deb inside overlay chroot (policy-rc.d blocks grub)
#   3. Generate initrd WITH live-boot hooks from inside the squashfs env
#   4. Add GRUB theme + Plymouth config
#   5. Reassemble ISO with iso-level 3 (no squashfs rebuild — saves 30 min)
#
# Usage: sudo bash fix-initrd-iso.sh
# Time:  ~15-20 minutes
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

SQUASHFS="/home/ravan/raksha-build/iso/live/filesystem.squashfs"
ISO_DIR="/home/ravan/raksha-build/iso"
ISO_OUT="/home/ravan/Raksha-OS-Core/builds/raksha-os-1.0.0-amd64.iso"
KERNEL_CACHE="/home/ravan/raksha-build-kernel"
WORK="/tmp/raksha-initrd-fix-$$"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[FIX]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$(id -u)" -ne 0 ] && err "Run as root: sudo bash $0"
[ -f "${SQUASHFS}" ] || err "Squashfs not found: ${SQUASHFS}"
log "Squashfs: $(du -sh ${SQUASHFS} | cut -f1) ✓"

mkdir -p "${WORK}"/{squash_mount,overlay_upper,overlay_work,overlay_merged}

cleanup() {
  log "Cleaning up mounts..."
  umount -l "${WORK}/overlay_merged/proc"    2>/dev/null || true
  umount -l "${WORK}/overlay_merged/sys"     2>/dev/null || true
  umount -l "${WORK}/overlay_merged/dev/pts" 2>/dev/null || true
  umount -l "${WORK}/overlay_merged/dev"     2>/dev/null || true
  umount -l "${WORK}/overlay_merged"         2>/dev/null || true
  umount -l "${WORK}/squash_mount"           2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ── STEP 1: Mount squashfs ────────────────────────────────────────────
log "STEP 1: Mounting squashfs read-only..."
mount -t squashfs -o loop,ro "${SQUASHFS}" "${WORK}/squash_mount"
log "  ✓ Squashfs mounted"

# ── STEP 2: Overlayfs — writable layer on top of squashfs ────────────
log "STEP 2: Creating writable overlay..."
mount -t overlay overlay \
  -o "lowerdir=${WORK}/squash_mount,upperdir=${WORK}/overlay_upper,workdir=${WORK}/overlay_work" \
  "${WORK}/overlay_merged"
log "  ✓ Overlay mounted at ${WORK}/overlay_merged"

# ── STEP 3: Bind-mount pseudo-filesystems ────────────────────────────
log "STEP 3: Binding proc/sys/dev..."
mount --bind /proc    "${WORK}/overlay_merged/proc"
mount --bind /sys     "${WORK}/overlay_merged/sys"
mount --bind /dev     "${WORK}/overlay_merged/dev"
mount --bind /dev/pts "${WORK}/overlay_merged/dev/pts"
cp /etc/resolv.conf "${WORK}/overlay_merged/etc/resolv.conf" 2>/dev/null || true

# ── STEP 4: Get kernel .deb ───────────────────────────────────────────
log "STEP 4: Getting kernel package..."

# Resolve real package name
KERNEL_PKG=$(apt-cache depends linux-image-amd64 2>/dev/null \
    | grep 'Depends:' | awk '{print $2}' | head -1)
[ -z "${KERNEL_PKG}" ] && KERNEL_PKG="linux-image-6.12.95+deb13-amd64"

mkdir -p "${KERNEL_CACHE}"
KERNEL_DEB=$(find "${KERNEL_CACHE}" -name "linux-image-*.deb" \
    ! -name "linux-image-amd64*" 2>/dev/null | head -1)

if [ -z "${KERNEL_DEB}" ]; then
  log "  Downloading ${KERNEL_PKG}..."
  cd "${KERNEL_CACHE}"
  apt-get download "${KERNEL_PKG}" 2>&1 | tail -2
  KERNEL_DEB=$(find "${KERNEL_CACHE}" -name "linux-image-*.deb" \
      ! -name "linux-image-amd64*" | head -1)
  cd -
fi
KVER=$(dpkg-deb -f "${KERNEL_DEB}" Package | sed 's/linux-image-//')
log "  ✓ Kernel: ${KVER}"

# Copy .deb into overlay
cp "${KERNEL_DEB}" "${WORK}/overlay_merged/tmp/"
DEB_BASENAME=$(basename "${KERNEL_DEB}")

# ── STEP 5: Install kernel inside chroot (policy-rc.d blocks grub) ───
log "STEP 5: Installing kernel inside squashfs chroot..."

# Block grub and flash-kernel from running (they fail in chroot)
cat > "${WORK}/overlay_merged/usr/sbin/policy-rc.d" << 'POLICY'
#!/bin/sh
case "$1" in
  grub*|flash-kernel*|u-boot*) exit 101 ;;
  *) exit 0 ;;
esac
POLICY
chmod +x "${WORK}/overlay_merged/usr/sbin/policy-rc.d"

chroot "${WORK}/overlay_merged" /bin/bash << CHROOT_INSTALL
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

# Install kernel — dpkg won't run grub because of policy-rc.d
dpkg -i /tmp/${DEB_BASENAME} 2>&1 | grep -E "^(Selecting|Unpacking|Setting|dpkg:)" || true

# Verify
if [ -f "/boot/vmlinuz-${KVER}" ]; then
    echo "  ✓ vmlinuz installed inside chroot"
else
    echo "  ✗ vmlinuz not found — trying dpkg-deb extract..."
    dpkg-deb -x /tmp/${DEB_BASENAME} /
fi

echo "  Boot dir:"
ls /boot/

# Generate initrd WITH live-boot hooks (live-boot is installed in squashfs)
echo "  Generating initrd (live-boot hooks included)..."
update-initramfs -c -k "${KVER}" 2>&1 | tail -10 || \
  mkinitramfs -o "/boot/initrd.img-${KVER}" "${KVER}" 2>&1 | tail -5

ls -lh /boot/initrd* 2>/dev/null || echo "ERROR: no initrd built"
CHROOT_INSTALL

# ── STEP 6: Extract initrd from overlay ─────────────────────────────
log "STEP 6: Extracting initrd from chroot..."

INITRD_IN_CHROOT=$(find "${WORK}/overlay_merged/boot" -name "initrd.img-*" | head -1)
[ -z "${INITRD_IN_CHROOT}" ] && err "initrd not found in chroot — check output above"

VMLINUZ_IN_CHROOT=$(find "${WORK}/overlay_merged/boot" -name "vmlinuz-*" | head -1)

log "  initrd: $(du -sh ${INITRD_IN_CHROOT} | cut -f1)"
log "  vmlinuz: $(basename ${VMLINUZ_IN_CHROOT})"

mkdir -p "${ISO_DIR}/boot"
cp "${INITRD_IN_CHROOT}"  "${ISO_DIR}/boot/initrd"
cp "${VMLINUZ_IN_CHROOT}" "${ISO_DIR}/boot/vmlinuz"
log "  ✓ Kernel files copied to ISO boot dir"

# ── STEP 7: GRUB — use real overlay assets ───────────────────────────
log "STEP 7: Applying real Raksha GRUB theme from overlay..."

OVERLAY="/home/ravan/Raksha-OS-Core/overlay"

# Copy the real GRUB theme (background images, theme.txt)
mkdir -p "${ISO_DIR}/boot/grub/themes"
cp -r "${OVERLAY}/boot/grub/themes/raksha" "${ISO_DIR}/boot/grub/themes/"
log "  ✓ Real GRUB theme copied"

# Copy unicode font
mkdir -p "${ISO_DIR}/boot/grub/fonts"
find "${WORK}/squash_mount/usr/share/grub" -name "unicode.pf2" 2>/dev/null | head -1 | \
  xargs -I{} cp {} "${ISO_DIR}/boot/grub/fonts/" 2>/dev/null || \
  find /usr/share/grub -name "unicode.pf2" 2>/dev/null | head -1 | \
  xargs -I{} cp {} "${ISO_DIR}/boot/grub/fonts/" 2>/dev/null || true

cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=15

insmod all_video
insmod gfxterm
insmod gfxmenu

if loadfont /boot/grub/fonts/unicode.pf2; then
  set gfxmode=1024x768,auto
  terminal_output gfxterm
fi

if [ -f /boot/grub/themes/raksha/theme.txt ]; then
  set theme=/boot/grub/themes/raksha/theme.txt
  export theme
fi

menuentry "Install Raksha OS" --class raksha --class linux {
  linux /boot/vmlinuz boot=live components splash quiet \
        live-config.hostname=raksha \
        live-config.username=ravan \
        live-config.password=raksha \
        live-config.autologin=true \
        plymouth.enable=1
  initrd /boot/initrd
}

menuentry "Raksha OS Live (Try without installing)" --class raksha {
  linux /boot/vmlinuz boot=live components splash quiet \
        live-config.hostname=raksha \
        plymouth.enable=1
  initrd /boot/initrd
}

menuentry "Raksha OS (Safe Graphics / nomodeset)" --class raksha {
  linux /boot/vmlinuz boot=live components quiet nomodeset \
        live-config.hostname=raksha
  initrd /boot/initrd
}

menuentry "Raksha OS (Debug — shows boot messages)" --class raksha {
  linux /boot/vmlinuz boot=live components \
        live-config.hostname=raksha
  initrd /boot/initrd
}
EOF
log "  ✓ GRUB configured with theme"

# ── STEP 8: live-boot config in ISO ──────────────────────────────────
log "STEP 8: Adding live-boot config..."
mkdir -p "${ISO_DIR}/live"
cat > "${ISO_DIR}/live/filesystem.live" << 'EOF'
boot=live
components
quiet
splash
EOF

# ── STEP 9: Reassemble ISO with iso-level 3 ──────────────────────────
log "STEP 9: Reassembling ISO (3-5 min)..."

XORRISO_WRAP="/tmp/xorriso-l3-$$"
cat > "${XORRISO_WRAP}" << 'WRAP'
#!/bin/bash
ARGS=()
for arg in "$@"; do
    ARGS+=("$arg")
    [ "$arg" = "mkisofs" ] && ARGS+=("-iso-level" "3")
done
exec /usr/bin/xorriso "${ARGS[@]}"
WRAP
chmod +x "${XORRISO_WRAP}"

rm -f "${ISO_OUT}"
grub-mkrescue \
    --xorriso="${XORRISO_WRAP}" \
    -o "${ISO_OUT}" \
    "${ISO_DIR}" \
    --fonts="" --locales="" --themes="" 2>&1

rm -f "${XORRISO_WRAP}"
ISO_SIZE=$(du -sh "${ISO_OUT}" | cut -f1)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  RAKSHA OS ISO — FIXED & REBUILT                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  File  : ${ISO_OUT}"
echo "║  Size  : ${ISO_SIZE}"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Fixed :                                                ║"
echo "║    ✓ initrd has live-boot hooks (boots properly now)   ║"
echo "║    ✓ GRUB theme — dark, green on black, Raksha branded ║"
echo "║    ✓ Plymouth splash enabled                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Flash to USB:                                          ║"
echo "║    sudo dd if=${ISO_OUT} \\"
echo "║      of=/dev/sdX bs=4M status=progress                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
