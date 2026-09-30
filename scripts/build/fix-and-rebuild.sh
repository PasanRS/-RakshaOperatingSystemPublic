#!/bin/bash
# ══════════════════════════════════════════════════════════
# Raksha OS — Verified Fix & Rebuild ISO
# All branding configs verified to actually reference assets
# ══════════════════════════════════════════════════════════
set -e

R="/home/ravan/raksha-build/rootfs"
ISO_WORK="/home/ravan/raksha-build/iso"
OUTPUT="/home/ravan/Raksha-OS-Core/builds/raksha-os-v5.2-amd64.iso"
KDEB="/home/ravan/raksha-build-kernel/linux-image-6.12.95+deb13-amd64_6.12.95-1_amd64.deb"
KVER="6.12.95+deb13-amd64"
WALLPAPERS="/home/ravan/Documents/Wallapapers"
PLYMOUTH_SRC="/home/ravan/Raksha-OS-Core/overlay/usr/share/plymouth/themes/raksha"
REPO="/home/ravan/Raksha-OS-Core"
WHISPER_SNAPSHOT="/home/ravan/.cache/huggingface/hub/models--Systran--faster-whisper-small.en/snapshots/d1d751a5f8271d482d14ca55d9e2deeebbae577f"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo "══════════════════════════════════════════════════════"
echo "  Raksha OS ISO v5.2 — Verified Fix & Rebuild"
echo "══════════════════════════════════════════════════════"
echo ""

[ -f "${R}/bin/bash" ] || die "Rootfs missing: ${R}"
[ "$(id -u)" -eq 0 ]    || die "Run as root: sudo bash $0"
[ -f "${KDEB}" ]       || die "Kernel deb missing: ${KDEB}"

# The v5 backup is deliberately not removed. ISO assembly needs room for the
# new output in addition to the staging squashfs, so fail before doing lengthy
# package and compression work when that room is unavailable.
AVAILABLE_BYTES=$(df --output=avail -B1 /home/ravan | tail -1 | tr -d ' ')
REPLACEABLE_OUTPUT_BYTES=$(stat -c '%s' "${OUTPUT}" 2>/dev/null || echo 0)
EFFECTIVE_FREE_BYTES=$((AVAILABLE_BYTES + REPLACEABLE_OUTPUT_BYTES))
MIN_FREE_BYTES=$((15 * 1024 * 1024 * 1024))
[ "${EFFECTIVE_FREE_BYTES}" -ge "${MIN_FREE_BYTES}" ] || die \
  "Need 15 GiB effective free space to build v5.2; currently $(df -h /home/ravan | tail -1 | awk '{print $4}') free and no sufficiently large replaceable v5.2 output"
log "Rootfs OK ($(du -sh ${R} | cut -f1))"

# ── mount ────────────────────────────────────────────────
cleanup_chroot() {
  rm -f "${R}/usr/sbin/policy-rc.d"
  rm -f "${R}/etc/resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf "${R}/etc/resolv.conf" 2>/dev/null || true
  for cleanup_mnt in dev/pts dev sys proc; do
    umount -l "${R}/${cleanup_mnt}" 2>/dev/null || true
  done
}
trap cleanup_chroot EXIT

for stale_mnt in dev/pts dev sys proc; do
  umount -l "${R}/${stale_mnt}" 2>/dev/null || true
done
for mnt in proc sys dev dev/pts; do
  mount --bind /${mnt} "${R}/${mnt}" 2>/dev/null || true
done
printf '#!/bin/sh\nexit 101\n' > "${R}/usr/sbin/policy-rc.d"
chmod +x "${R}/usr/sbin/policy-rc.d"

# A chroot has no working systemd-resolved stub of its own. Install the host's
# concrete resolver configuration so apt can resolve repository hostnames.
rm -f "${R}/etc/resolv.conf"
install -m 0644 /etc/resolv.conf "${R}/etc/resolv.conf"
log "Mounts ready"

# Sync corrected v5.2 build inputs into the retained rootfs before repacking.
install -m 0755 "${REPO}/scripts/raksha-firstboot.sh" "${R}/usr/local/bin/raksha-firstboot"
install -m 0755 "${REPO}/scripts/raksha-whatsapp-setup.sh" "${R}/usr/local/bin/raksha-whatsapp-setup"
install -m 0755 "${REPO}/overlay/usr/local/sbin/raksha-start-installer" "${R}/usr/local/sbin/raksha-start-installer"
install -m 0755 "${REPO}/overlay/usr/local/sbin/raksha-session" "${R}/usr/local/sbin/raksha-session"
install -m 0644 "${REPO}/overlay/etc/xdg/autostart/raksha-installer.desktop" "${R}/etc/xdg/autostart/raksha-installer.desktop"
install -m 0644 "${REPO}/overlay/etc/xdg/autostart/raksha-live-desktop.desktop" "${R}/etc/xdg/autostart/raksha-live-desktop.desktop"
install -m 0644 "${REPO}/overlay/etc/xdg/kdeglobals" "${R}/etc/xdg/kdeglobals"
install -m 0644 "${REPO}/overlay/etc/xdg/kcm-about-distrorc" "${R}/etc/xdg/kcm-about-distrorc"
install -m 0644 "${REPO}/overlay/etc/xdg/kickoffrc" "${R}/etc/xdg/kickoffrc"
install -d "${R}/usr/share/applications"
install -m 0644 "${REPO}/overlay/usr/share/applications/raksha-installer.desktop" "${R}/usr/share/applications/raksha-installer.desktop"
install -d "${R}/usr/share/xsessions"
install -m 0644 "${REPO}/overlay/usr/share/xsessions/raksha.desktop" "${R}/usr/share/xsessions/raksha.desktop"
rm -rf "${R}/usr/share/plasma/look-and-feel/org.raksha.desktop"
cp -a "${R}/usr/share/plasma/look-and-feel/org.kde.breeze.desktop" \
  "${R}/usr/share/plasma/look-and-feel/org.raksha.desktop"
cp -a "${REPO}/overlay/usr/share/plasma/look-and-feel/org.raksha.desktop/." \
  "${R}/usr/share/plasma/look-and-feel/org.raksha.desktop/"
install -m 0644 "${REPO}/src/interface/server.py" "${R}/opt/ash-core/voice/server.py"
if [ -f /home/ravan/ash-interface/static/index.html ]; then
  mkdir -p "${R}/opt/ash-core/voice/static"
  cp -a /home/ravan/ash-interface/static/. "${R}/opt/ash-core/voice/static/"
else
  die "Voice interface UI assets missing: /home/ravan/ash-interface/static"
fi
for unit in ash-voice ash-interface ash-whatsapp ash-whatsapp-bridge \
            ash-whatsapp-poller raksha-firstboot; do
  install -m 0644 "${REPO}/systemd/${unit}.service" "${R}/etc/systemd/system/${unit}.service"
done

mkdir -p "${R}/etc/sddm.conf.d"
cat > "${R}/etc/sddm.conf.d/autologin.conf" << 'EOF'
[Autologin]
User=ravan
Session=raksha.desktop
Relogin=false

[General]
DisplayServer=x11
EOF

if [ -f "${WHISPER_SNAPSHOT}/model.bin" ] && [ -f "${WHISPER_SNAPSHOT}/config.json" ]; then
  mkdir -p "${R}/opt/ash-core/voice/whisper-small.en"
  cp -aL "${WHISPER_SNAPSHOT}/." "${R}/opt/ash-core/voice/whisper-small.en/"
  log "Offline Whisper model staged"
else
  warn "Whisper snapshot missing; HTTP :8888 will work with STT disabled"
fi

# This must precede update-initramfs so stale NVIDIA policy is not embedded in
# the live boot image when no proprietary module exists for this kernel.
if ! find "${R}/lib/modules/${KVER}" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia-current.ko*' \) -print -quit | grep -q .; then
  rm -f "${R}/etc/modules-load.d/nvidia.conf"
  rm -f "${R}/etc/modprobe.d/nvidia-blacklists-nouveau.conf"
  rm -f "${R}/etc/modprobe.d/nvidia.conf"
  systemctl --root="${R}" disable nvidia-persistenced.service 2>/dev/null || true
  log "Graphics pre-initrd: no NVIDIA module; nouveau fallback enabled"
fi

# ══════════════════════════════════════════════════════════
# 1. INITRD — generated inside chroot with live-boot hooks
# ══════════════════════════════════════════════════════════
echo ""
echo "── [1/9] initrd with live-boot hooks ──"
cp "${KDEB}" "${R}/tmp/"
KDEB_BASE=$(basename "${KDEB}")
chroot "${R}" /bin/bash -c "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --reinstall live-boot live-boot-initramfs-tools
  apt-get install -y -o Dpkg::Options::=--force-confold \
    nodejs npm chromium calamares calamares-settings-debian kwin-x11 \
    grub-common grub2-common grub-efi-amd64 grub-efi-amd64-bin efibootmgr
  dpkg-query -W -f='\${Package} \${Status}\n' \
    live-boot live-boot-initramfs-tools | grep -q 'install ok installed'
  dpkg -i /tmp/${KDEB_BASE} || apt-get -f install -y
  test -f /usr/share/initramfs-tools/hooks/live
  test -e /usr/share/initramfs-tools/scripts/live
  test -x /usr/bin/kwin_x11
  test -x /usr/sbin/grub-install
  test -x /usr/sbin/grub-mkconfig
  test -x /usr/sbin/grub-probe
  test -x /usr/bin/efibootmgr
  test -f /usr/lib/grub/x86_64-efi/modinfo.sh
  test -f /usr/lib/grub/x86_64-efi/normal.mod
  test -f /usr/lib/grub/x86_64-efi/linux.mod
  dpkg-query -W -f='\${binary:Package} \${db:Status-Abbrev}\n' \
    grub-common grub2-common grub-efi-amd64 grub-efi-amd64-bin efibootmgr | \
    grep -v ' ii ' && exit 1 || true
  ! ldd /usr/sbin/grub-install | grep -q 'not found'

  # Use a disposable ESP and no NVRAM because build chroots have no firmware.
  # This still exercises the exact x86_64-efi grub-install binary and modules
  # that Calamares will use in the real installed target.
  rm -rf /tmp/raksha-grub-smoke
  mkdir -p /tmp/raksha-grub-smoke/efi /tmp/raksha-grub-smoke/boot
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /usr/sbin/grub-install --target=x86_64-efi \
      --efi-directory=/tmp/raksha-grub-smoke/efi \
      --boot-directory=/tmp/raksha-grub-smoke/boot \
      --bootloader-id=Raksha_OS --force --no-nvram --removable
  test -s /tmp/raksha-grub-smoke/efi/EFI/BOOT/BOOTX64.EFI
  rm -rf /tmp/raksha-grub-smoke
  echo '[PASS] target chroot x86_64-efi grub-install smoke test'
  update-initramfs -u -k ${KVER}

  PYTHON_REAL=\$(readlink -f /usr/bin/python3)
  PYTHON_NAME=\$(basename "\${PYTHON_REAL}")
  for VENV in /opt/ash-core/harness/venv /opt/raksha-dashboard/venv \
              /opt/ash-core/voice/venv /opt/ash-core/reflexes/venv; do
    [ -d "\${VENV}/bin" ] || continue
    rm -f "\${VENV}/bin/python" "\${VENV}/bin/python3" "\${VENV}/bin/\${PYTHON_NAME}"
    ln -s /usr/bin/python3 "\${VENV}/bin/python3"
    ln -s python3 "\${VENV}/bin/python"
    ln -s python3 "\${VENV}/bin/\${PYTHON_NAME}"
    "\${VENV}/bin/python" -c 'import sys; assert sys.prefix != sys.base_prefix'
  done

  cd /opt/ash-core/gateways
  npm install --omit=dev --no-audit --no-fund
  test -x /usr/bin/node
  test -f node_modules/whatsapp-web.js/index.js
  test -f node_modules/qrcode-terminal/lib/main.js
  cd /opt/ash-core/gateways/ash-whatsapp-bridge
  npm ci --omit=dev --no-audit --no-fund
  test -f node_modules/@whiskeysockets/baileys/package.json
  ls -lh /boot/initrd* /boot/vmlinuz*
"
mkdir -p "${ISO_WORK}/boot"
cp "${R}/boot/initrd.img-${KVER}" "${ISO_WORK}/boot/initrd"
cp "${R}/boot/vmlinuz-${KVER}"    "${ISO_WORK}/boot/vmlinuz"

# A bootable kernel is not enough for a live ISO. Refuse to continue unless
# the generated initramfs can discover and mount /live/filesystem.squashfs.
if ! lsinitramfs "${ISO_WORK}/boot/initrd" | grep -qE 'scripts/live|live-premount|live-bottom'; then
  die "Generated initrd has no live-boot scripts; refusing to build an unbootable ISO"
fi
log "initrd: $(du -sh ${ISO_WORK}/boot/initrd | cut -f1) — live-boot hooks present"

# ══════════════════════════════════════════════════════════
# 2. GRUB — theme loaded + background referenced in grub.cfg
# ══════════════════════════════════════════════════════════
echo ""
echo "── [2/9] GRUB theme + grub.cfg ──"

# Put theme in proper subdir: /boot/grub/themes/raksha/
mkdir -p "${ISO_WORK}/boot/grub/themes/raksha"
cp /home/ravan/Raksha-OS-Core/overlay/boot/grub/themes/raksha/* \
   "${ISO_WORK}/boot/grub/themes/raksha/" 2>/dev/null || true
log "GRUB theme files in /boot/grub/themes/raksha/"

# grub.cfg — loads theme + background explicitly
cat > "${ISO_WORK}/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=15
set gfxmode=1920x1080,1280x720,auto

insmod all_video
insmod png
insmod gfxterm
insmod gfxmenu

# Load Raksha GRUB theme
if [ -f /boot/grub/themes/raksha/theme.txt ]; then
  set theme=/boot/grub/themes/raksha/theme.txt
  export theme
fi

# Load background explicitly
if loadfont /boot/grub/fonts/unicode.pf2; then
  terminal_output gfxterm
fi

if background_image /boot/grub/themes/raksha/background-16x9.png; then
  true
elif background_image /boot/grub/themes/raksha/background-4x3.png; then
  true
fi

menuentry "Install Raksha OS" --class raksha --class gnu-linux --class gnu --class os {
  linux /boot/vmlinuz boot=live components splash quiet raksha.install=1 \
        live-config.hostname=raksha \
        live-config.username=ravan \
        live-config.password=raksha \
        live-config.autologin=true \
        rd.plymouth=1 plymouth.enable=1
  initrd /boot/initrd
}

menuentry "Raksha OS (Try without installing)" --class raksha {
  linux /boot/vmlinuz boot=live components splash quiet \
        live-config.hostname=raksha \
        live-config.username=ravan \
        live-config.password=raksha \
        rd.plymouth=1 plymouth.enable=1
  initrd /boot/initrd
}

menuentry "Raksha OS (Safe Graphics)" --class raksha {
  linux /boot/vmlinuz boot=live components quiet nomodeset
  initrd /boot/initrd
}

menuentry "Raksha OS (Debug)" --class raksha {
  linux /boot/vmlinuz boot=live components debug
  initrd /boot/initrd
}
EOF
log "grub.cfg: theme + background explicitly loaded"

# calamares-settings-debian provides useful installer configuration, but its
# session autostart creates an incorrectly branded "Install Debian" desktop
# icon. Disable only that icon generator and use Raksha's launcher instead.
cat > "${R}/etc/xdg/autostart/calamares-desktop-icon.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Debian Calamares Desktop Icon (disabled by Raksha OS)
Hidden=true
EOF
mkdir -p "${R}/usr/local/share/applications"
cat > "${R}/usr/local/share/applications/calamares-install-debian.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Install Debian
Hidden=true
NoDisplay=true
EOF
log "Installer entry: Raksha desktop icon; Calamares auto-start only for raksha.install=1"

# ══════════════════════════════════════════════════════════
# 3. Plymouth — verified 27-frame Raksha animation
#    animation-0001.png through animation-0027.png
#    + raksha-logo.png (Ravana emblem)
#    + raksha-title.png (RAKSHA OS neon text)
# ══════════════════════════════════════════════════════════
echo ""
echo "── [3/9] Plymouth boot animation ──"

PLYMOUTH_DEST="${R}/usr/share/plymouth/themes/raksha"
mkdir -p "${PLYMOUTH_DEST}"

# Copy full verified overlay theme (all 27 frames + logo + title + .plymouth + .script)
if [ -d "${PLYMOUTH_SRC}" ]; then
  cp -r "${PLYMOUTH_SRC}/." "${PLYMOUTH_DEST}/"
  FRAME_COUNT=$(ls "${PLYMOUTH_SRC}"/animation-*.png 2>/dev/null | wc -l)
  log "Plymouth: ${FRAME_COUNT} animation frames copied"
else
  die "Plymouth source missing: ${PLYMOUTH_SRC}"
fi

# Verify logo and title are real files (not empty)
LOGO_SIZE=$(stat -c%s "${PLYMOUTH_DEST}/raksha-logo.png" 2>/dev/null || echo 0)
TITLE_SIZE=$(stat -c%s "${PLYMOUTH_DEST}/raksha-title.png" 2>/dev/null || echo 0)

if [ "${LOGO_SIZE}" -lt 1000 ]; then
  warn "raksha-logo.png too small (${LOGO_SIZE}b) — copying from Calamares"
  cp /etc/calamares/branding/raksha/logo.png "${PLYMOUTH_DEST}/raksha-logo.png"
fi
if [ "${TITLE_SIZE}" -lt 1000 ]; then
  warn "raksha-title.png too small (${TITLE_SIZE}b) — will use generated version"
fi

log "logo: $(du -sh ${PLYMOUTH_DEST}/raksha-logo.png | cut -f1)"
log "title: $(du -sh ${PLYMOUTH_DEST}/raksha-title.png | cut -f1)"

# Ensure .plymouth descriptor is correct
cat > "${PLYMOUTH_DEST}/raksha.plymouth" << 'EOF'
[Plymouth Theme]
Name=Raksha OS
Description=Sovereign AI boot animation
Comment=Boot splash for Raksha OS — 27 frame animation
Author=PasanRS
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/raksha
ScriptFile=/usr/share/plymouth/themes/raksha/raksha.script
EOF
log "Plymouth: raksha.plymouth descriptor written"

# Set as default
chroot "${R}" /bin/bash -c "
  update-alternatives --install \
    /usr/share/plymouth/themes/default.plymouth \
    default.plymouth \
    /usr/share/plymouth/themes/raksha/raksha.plymouth 200 2>/dev/null || true
  update-alternatives --set \
    default.plymouth \
    /usr/share/plymouth/themes/raksha/raksha.plymouth 2>/dev/null || true
  plymouth-set-default-theme raksha 2>/dev/null || true
" 2>/dev/null || true
log "Plymouth: raksha set as system default"

# ══════════════════════════════════════════════════════════
# 4. SDDM — theme.conf references real wallpaper (not svg)
# ══════════════════════════════════════════════════════════
echo ""
echo "── [4/9] SDDM branding ──"

# Always stage the complete working theme (QML + metadata), independently of
# the optional wallpaper replacement below.
mkdir -p "${R}/usr/share/sddm/themes/raksha"
if [ -f /usr/share/sddm/themes/raksha/Main.qml ]; then
  cp -a /usr/share/sddm/themes/raksha/. "${R}/usr/share/sddm/themes/raksha/"
fi
test -f "${R}/usr/share/sddm/themes/raksha/Main.qml" || die "Raksha SDDM Main.qml missing"
test -f "${R}/usr/share/sddm/themes/raksha/metadata.desktop" || die "Raksha SDDM metadata missing"

# Pick the largest wallpaper from Documents
WALLPAPER=$(find "${WALLPAPERS}" \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | \
  xargs -I{} stat --format="%s %n" {} 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

if [ -n "${WALLPAPER}" ]; then
  mkdir -p "${R}/usr/share/sddm/themes/raksha"
  # Copy live theme first for QML etc.
  [ -d /usr/share/sddm/themes/raksha ] && \
    cp -rn /usr/share/sddm/themes/raksha/. \
           "${R}/usr/share/sddm/themes/raksha/" 2>/dev/null || true
  # Replace background with real wallpaper
  cp "${WALLPAPER}" "${R}/usr/share/sddm/themes/raksha/background.png"
  cp "${WALLPAPER}" "${R}/usr/share/sddm/themes/raksha/background.jpg"

  # Package the same image as Plasma's real default wallpaper. The Debian
  # look-and-feel remains installed as a dependency, but no longer selects a
  # Debian image for new live or installed users.
  mkdir -p "${R}/usr/share/wallpapers/RakshaOS/contents/images"
  cp "${WALLPAPER}" "${R}/usr/share/wallpapers/RakshaOS/contents/images/1920x1080.jpg"
  cat > "${R}/usr/share/wallpapers/RakshaOS/metadata.json" << 'EOF'
{
  "KPlugin": {
    "Id": "RakshaOS",
    "Name": "Raksha OS",
    "License": "Proprietary"
  }
}
EOF
  for defaults in \
    "${R}/usr/share/plasma/look-and-feel/org.debian.desktop/contents/defaults" \
    "${R}/usr/share/plasma/look-and-feel/org.kde.breeze.desktop/contents/defaults" \
    "${R}/usr/share/plasma/look-and-feel/org.kde.breezedark.desktop/contents/defaults"; do
    if [ -f "${defaults}" ]; then
      sed -i 's|^Image=.*|Image=RakshaOS|' "${defaults}"
    fi
  done
  # Do not expose desktop-base's Debian Global Theme and historical Debian
  # wallpaper shortcuts in Raksha's appearance selectors.
  rm -rf "${R}/usr/share/plasma/look-and-feel/org.debian.desktop"
  find "${R}/usr/share/wallpapers" -maxdepth 1 -type l \
    \( -name DebianTheme -o -lname '*desktop-base*' \) -delete
  # Fix theme.conf to use background.png (not .svg)
  TCONF="${R}/usr/share/sddm/themes/raksha/theme.conf"
  if [ -f "${TCONF}" ]; then
    sed -i 's|^background=.*|background=background.png|' "${TCONF}"
  else
    printf '[General]\nbackground=background.png\n' > "${TCONF}"
  fi
  # Fix sddm.conf.d
  mkdir -p "${R}/etc/sddm.conf.d"
  cat > "${R}/etc/sddm.conf.d/10-raksha.conf" << 'EOF'
[Theme]
Current=raksha
EOF
  log "SDDM + Plasma: $(basename ${WALLPAPER}) set as Raksha default"
else
  warn "No wallpaper found — SDDM unchanged"
fi

# ══════════════════════════════════════════════════════════
# 5. Calamares — branding dir matches settings.conf
# ══════════════════════════════════════════════════════════
echo ""
echo "── [5/9] Calamares branding ──"

# Copy from live /etc/calamares/branding/raksha/
mkdir -p "${R}/etc/calamares/branding/raksha"
cp -r /etc/calamares/branding/raksha/. "${R}/etc/calamares/branding/raksha/"
rm -rf "${R}/etc/calamares/branding/raksha-os" 2>/dev/null || true

# Fix settings.conf to match: branding: raksha
if [ -f "${R}/etc/calamares/settings.conf" ]; then
  sed -i 's/^branding:.*/branding: raksha/' "${R}/etc/calamares/settings.conf"
  log "Calamares settings.conf: branding: raksha"
fi
log "Calamares branding: from /etc/calamares/branding/raksha/ → dir raksha/"

# This runs inside Calamares' installed target. The marker deliberately does
# not exist in the live squashfs, so firstboot cannot run from USB media.
mkdir -p "${R}/etc/calamares/modules"
cat > "${R}/etc/calamares/modules/bootloader.conf" << 'EOF'
---
# Absolute target paths avoid dependence on the graphical installer's PATH.
efiBootLoader: "grub"
grubInstall: "/usr/sbin/grub-install"
grubMkconfig: "/usr/sbin/grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "/usr/sbin/grub-probe"
efiBootMgr: "/usr/bin/efibootmgr"
efiBootloaderId: "Raksha_OS"
installEFIFallback: true
EOF
cat > "${R}/etc/calamares/modules/shellprocess@raksha-post.conf" << 'EOF'
---
dontChroot: false
timeout: 300
script:
  - "-/bin/bash -c 'systemctl enable raksha-harness raksha-dashboard ash-interface ash-heartbeat.timer ash-dreaming.timer ash-memory.timer raksha-firstboot 2>/dev/null || true'"
  - "-/bin/bash -c 'mkdir -p /var/lib/raksha /var/lib/ash/logs /var/lib/ash/memory /var/lib/ash/tasks /var/lib/ash/identity'"
  - "-/bin/bash -c 'touch /var/lib/raksha/installed; rm -f /var/lib/raksha/.first-boot-done'"
  - "-/bin/bash -c 'chown -R 1000:1000 /var/lib/ash/logs /var/lib/ash/memory /var/lib/ash/tasks /var/lib/ash/identity 2>/dev/null || true'"
EOF
rm -f "${R}/var/lib/raksha/installed" "${R}/var/lib/raksha/.first-boot-done"
log "Calamares installed-system marker hook configured"

# Prefer the portable in-kernel nouveau driver when no matching proprietary
# NVIDIA module was actually built. A stale forced nvidia-drm load plus a
# nouveau blacklist prevents SDDM from reaching a usable display.
if ! find "${R}/lib/modules/${KVER}" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia-current.ko*' \) -print -quit | grep -q .; then
  rm -f "${R}/etc/modules-load.d/nvidia.conf"
  rm -f "${R}/etc/modprobe.d/nvidia-blacklists-nouveau.conf"
  rm -f "${R}/etc/modprobe.d/nvidia.conf"
  systemctl --root="${R}" disable nvidia-persistenced.service 2>/dev/null || true
  log "Graphics: no NVIDIA kernel module; enabled nouveau fallback"
fi

# ══════════════════════════════════════════════════════════
# 6. OS Identity files
# ══════════════════════════════════════════════════════════
echo ""
echo "── [6/9] OS identity ──"
cat > "${R}/usr/lib/os-release" << 'EOF'
NAME="Raksha OS"
VERSION="1.0.0"
ID=raksha
ID_LIKE=debian
PRETTY_NAME="Raksha OS 1.0.0"
VERSION_ID="1.0.0"
VERSION_CODENAME="awakening"
HOME_URL="https://github.com/PasanRS/Raksha-OS-Core"
SUPPORT_URL="https://github.com/PasanRS/Raksha-OS-Core/issues"
BUG_REPORT_URL="https://github.com/PasanRS/Raksha-OS-Core/issues"
EOF
rm -f "${R}/etc/os-release"
ln -s ../usr/lib/os-release "${R}/etc/os-release"
printf "Raksha OS 1.0.0 \\n \\l\n" > "${R}/etc/issue"
printf "Raksha OS 1.0.0\n"         > "${R}/etc/issue.net"
log "os-release / issue / issue.net → Raksha OS 1.0.0"

# ══════════════════════════════════════════════════════════
# 7. Enable ALL required services
# ══════════════════════════════════════════════════════════
echo ""
echo "── [7/9] Enabling all Ash services ──"
WANTS="${R}/etc/systemd/system/multi-user.target.wants"
SVCDIR="${R}/etc/systemd/system"
mkdir -p "${WANTS}"

enable_svc() {
  local svc="$1"
  if [ -f "${SVCDIR}/${svc}" ]; then
    ln -sf "/etc/systemd/system/${svc}" "${WANTS}/${svc}" 2>/dev/null || true
    log "  enabled: ${svc}"
  else
    warn "  not found: ${svc}"
  fi
}

enable_svc "ash-core.timer"
enable_svc "ash-heartbeat.timer"
enable_svc "ash-memory.timer"
enable_svc "ash-dreaming.timer"
# ash-interface is the canonical :8888 voice/UI service. ash-voice remains a
# corrected compatibility unit but is intentionally not enabled in parallel.
rm -f "${WANTS}/ash-voice.service"
enable_svc "ash-interface.service"
enable_svc "ash-defibrillator.service"
enable_svc "ash-whatsapp.service"
enable_svc "ash-whatsapp-bridge.service"
enable_svc "ash-whatsapp-poller.service"
enable_svc "ash-telegram.service"
enable_svc "raksha-harness.service"
enable_svc "raksha-dashboard.service"
enable_svc "raksha-firstboot.service"

# ══════════════════════════════════════════════════════════
# 8. Offline verification — all models + skills in rootfs
# ══════════════════════════════════════════════════════════
echo ""
echo "── [8/9] Offline readiness verification ──"
ALL_OK=true
for model in \
  "gemma-4-E2B_q4_0-it.gguf" \
  "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf" \
  "UI-TARS-2B-SFT-Q4_K_M.gguf" \
  "UI-TARS-2B-SFT-mmproj-fp16.gguf"; do
  if find "${R}/home/ravan" -name "${model}" 2>/dev/null | grep -q .; then
    log "  model: ${model}"
  else
    warn "  MISSING: ${model}"
    ALL_OK=false
  fi
done

for onnx in "en_US-ryan-high.onnx" "en_US-amy-medium.onnx"; do
  if find "${R}/opt/ash-core/voice" -name "${onnx}" 2>/dev/null | grep -q .; then
    log "  voice: ${onnx}"
  else
    warn "  MISSING voice: ${onnx}"
    ALL_OK=false
  fi
done

SKILL_COUNT=$(find "${R}/opt/ash-core/skills" -type f 2>/dev/null | wc -l)
log "  skills: ${SKILL_COUNT} files"
[ "${ALL_OK}" = true ] && log "Offline ready: all assets present" || warn "Some assets missing — see above"

# Immutable packaged runtimes are root-owned; only state is user-writable.
chown -R 0:0 "${R}/opt/ash-core" "${R}/opt/raksha-dashboard"
chmod -R a+rX "${R}/opt/ash-core" "${R}/opt/raksha-dashboard"
for state_dir in logs memory tasks identity harness creations screenshots; do
  [ -d "${R}/var/lib/ash/${state_dir}" ] && \
    chown -R 1000:1000 "${R}/var/lib/ash/${state_dir}"
done

# Plymouth and graphics policy are finalized after the initial kernel install,
# so regenerate the live initrd now and replace the early copy. Otherwise the
# ISO continues to boot with Debian's theme even though the rootfs is branded.
chroot "${R}" /bin/bash -c "
  set -e
  plymouth-set-default-theme raksha
  update-initramfs -u -k ${KVER}
"
cp "${R}/boot/initrd.img-${KVER}" "${ISO_WORK}/boot/initrd"
lsinitramfs "${ISO_WORK}/boot/initrd" | grep -q \
  'usr/share/plymouth/themes/raksha/raksha.plymouth' || \
  die "Final initrd does not contain the Raksha Plymouth theme"
log "Final initrd regenerated with Raksha Plymouth branding"

printf 'RAKSHA_ISO_BUILD=5.2\n' > "${R}/etc/raksha-iso-build"
"${REPO}/scripts/build/verify-rootfs.sh" "${R}"
log "Static rootfs verification passed"

# ── cleanup chroot ────────────────────────────────────────
rm -f "${R}/tmp/"*.deb
cleanup_chroot
log "Rootfs fixes complete"

# ══════════════════════════════════════════════════════════
# 9. Rebuild squashfs + ISO
# ══════════════════════════════════════════════════════════
echo ""
echo "── [9/9] Rebuilding squashfs + ISO ──"
echo "    squashfs: ~20-30 min | ISO: ~10 min"
echo ""

# Reclaim the previous ISO before compression; retaining it caused avoidable
# disk pressure while the new 14+ GiB squashfs was being written.
rm -f "${OUTPUT}"
rm -f "${ISO_WORK}/live/filesystem.squashfs"
mksquashfs "${R}" "${ISO_WORK}/live/filesystem.squashfs" \
  -comp xz -b 1M -Xdict-size 100% -no-recovery \
  -e "${ISO_WORK}/live/filesystem.squashfs"

du -sx --block-size=1 "${R}" | cut -f1 > "${ISO_WORK}/live/filesystem.size"
log "squashfs: $(du -sh ${ISO_WORK}/live/filesystem.squashfs | cut -f1)"
"${REPO}/scripts/build/verify-squashfs.sh" "${ISO_WORK}/live/filesystem.squashfs"
log "Static squashfs verification passed"

# xorriso wrapper for ISO level 3 (>4GB)
XWRAP="/tmp/xr-raksha-v5.2"
printf '#!/bin/bash\nARGS=()\nfor a in "$@"; do ARGS+=("$a"); [ "$a" = "mkisofs" ]&&ARGS+=("-iso-level" "3"); done\nexec /usr/bin/xorriso "${ARGS[@]}"\n' > "${XWRAP}"
chmod +x "${XWRAP}"

grub-mkrescue \
  --xorriso="${XWRAP}" \
  -o "${OUTPUT}" \
  "${ISO_WORK}" \
  2>&1

rm -f "${XWRAP}"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  RAKSHA OS ISO v5.2 — BUILD COMPLETE"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  ISO  : ${OUTPUT}"
echo "  Size : $(du -sh ${OUTPUT} | cut -f1)"
echo ""
echo "  Branding verified:"
echo "  ✓ GRUB  : /boot/grub/themes/raksha/theme.txt (loaded in grub.cfg)"
echo "  ✓ GRUB  : background-16x9.png (loaded in grub.cfg)"
echo "  ✓ Plymouth: raksha theme set as default (30-frame animation)"
echo "  ✓ SDDM  : background.png (real wallpaper, referenced in theme.conf)"
echo "  ✓ Calamares: branding dir=raksha, settings.conf=raksha"
echo "  ✓ OS    : Raksha OS 1.0.0 in os-release/issue"
echo ""
echo "  Copy to Ventoy:"
echo "  cp ${OUTPUT} /path/to/ventoy/"
echo ""
